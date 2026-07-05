from __future__ import annotations

import json
import time

from app.llm.base import StreamChunk, get_llm_client
from app.main import app
from app.routers import chapters as chapters_router
from tests.conftest import MockLLMClient, override_all_llm_clients


class SlowStreamLLM(MockLLMClient):
    def complete_stream(self, *, system: str, user: str, **kwargs):
        time.sleep(0.03)
        yield StreamChunk(kind="token", text="迟到的第一句。")


class FailingStreamLLM(MockLLMClient):
    def complete_stream(self, *, system: str, user: str, **kwargs):
        raise RuntimeError("writer exploded")
        yield ""


class BadExtractorLLM(MockLLMClient):
    def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
        context = json.loads(user)
        if "all_characters" in context:
            return super().complete_json(system=system, user=user, schema=schema, **kwargs)
        return {
            "summary": "坏输出不应落库",
            "timeline_events": [
                {
                    "character_id": "00000000-0000-0000-0000-000000000000",
                    "event_type": "action",
                    "event_text": "不存在的角色做了事。",
                }
            ],
            "character_updates": [],
        }


def _seed_book_character(client, auth_headers):
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "长夜", "cover_color": "#111111"},
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎、敏锐", "background": "退役的痕迹追踪员"},
            "live_fields": {"current_status": "调查失踪案"},
        },
    ).json()
    return book, character


def _parse_sse(text: str):
    events = []
    for block in text.strip().split("\n\n"):
        if not block:
            continue
        if block.startswith(":"):
            events.append(("comment", block, None))
            continue
        lines = block.splitlines()
        event = lines[0].removeprefix("event: ").strip()
        data = json.loads(lines[1].removeprefix("data: ").strip())
        events.append((event, block, data))
    return events


def test_chapter_agent_flow(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)

    created = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "雨夜", "user_prompt": "林夕在山洞找到关键线索。"},
    )
    assert created.status_code == 201
    chapter = created.json()
    assert chapter["index"] == 1
    assert chapter["status"] == "draft"

    expanded = client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    assert expanded.status_code == 200
    chapter = expanded.json()
    assert chapter["status"] == "prompt_ready"
    assert chapter["structured_prompt"]["characters_involved"] == [character["id"]]

    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as response:
        stream_text = "".join(response.iter_text())
    assert response.status_code == 200
    events = _parse_sse(stream_text)
    event_names = [event[0] for event in events]
    assert "started" in event_names
    assert "token" in event_names
    assert "progress" in event_names
    assert "done" in event_names
    done = [event for event in events if event[0] == "done"][0][2]
    assert done["chapter"]["status"] == "draft_ready"

    written = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert written["status"] == "draft_ready"
    assert "带血的铜钱" in written["draft_text"]

    finalized = client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)
    assert finalized.status_code == 200
    payload = finalized.json()
    assert payload["chapter"]["status"] == "finalized"
    assert payload["updated_character_ids"] == [character["id"]]
    assert len(payload["added_event_ids"]) == 1

    timeline = client.get(f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers)
    assert timeline.status_code == 200
    assert timeline.json()["items"][0]["event_text"] == "在山洞中发现带血铜钱。"

    updated_character = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert updated_character["live_fields"]["current_status"] == "带着铜钱离开山洞"

    reopened = client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers)
    assert reopened.status_code == 200
    assert reopened.json()["status"] == "draft_ready"
    assert reopened.json()["summary"] is None
    assert client.get(f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers).json()["items"] == []


def test_state_conflicts(client, auth_headers):
    book, _ = _seed_book_character(client, auth_headers)
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "先不要写。"},
    ).json()

    write = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert write.status_code == 409
    assert write.json()["error"]["kind"] == "conflict"

    finalize = client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)
    assert finalize.status_code == 409
    assert finalize.json()["error"]["kind"] == "conflict"

    invalid_patch = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"structured_prompt": {}},
    )
    assert invalid_patch.status_code == 422
    assert invalid_patch.json()["error"]["kind"] == "validation"


def test_writer_stream_keepalive_and_error_restore_status(client, auth_headers, monkeypatch):
    book, _ = _seed_book_character(client, auth_headers)
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "慢慢写。"},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)

    monkeypatch.setattr(chapters_router, "KEEPALIVE_SECONDS", 0.01)
    # M-1: /write now Depends(get_writer_llm_client); update every LLM dep so
    # the test's mock applies regardless of which Agent the router resolves.
    override_all_llm_clients(lambda: SlowStreamLLM())
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as response:
        text = "".join(response.iter_text())
    assert response.status_code == 200
    assert ": keepalive" in text
    assert "event: done" in text

    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"structured_prompt": {"chapter_goal": "重试写作"}},
    )
    override_all_llm_clients(lambda: FailingStreamLLM())
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as response:
        error_text = "".join(response.iter_text())
    assert response.status_code == 200
    assert "event: error" in error_text
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["status"] == "draft_ready"


def test_finalize_rolls_back_bad_extractor_output(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林夕在山洞找到关键线索。"},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as response:
        _ = "".join(response.iter_text())
    assert response.status_code == 200

    override_all_llm_clients(lambda: BadExtractorLLM())
    finalized = client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)
    assert finalized.status_code == 502
    assert finalized.json()["error"]["kind"] == "upstream"

    chapter_after = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert chapter_after["status"] == "draft_ready"
    assert chapter_after["summary"] is None
    timeline = client.get(f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers).json()
    assert timeline["items"] == []
    character_after = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert character_after["live_fields"]["current_status"] == "调查失踪案"
