from __future__ import annotations

import json
from typing import Any

import pytest

from app.llm.base import get_llm_client
from app.main import app
from tests.conftest import MockLLMClient, override_all_llm_clients


def _seed_book_character(client, auth_headers) -> tuple[dict, dict]:
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
            "frozen_fields": {"core_traits": "谨慎、敏锐", "voice": "说话简短"},
            "live_fields": {"current_status": "调查失踪案"},
        },
    ).json()
    return book, character


def _new_chapter(client, auth_headers, book_id: str, prompt: str = "导入测试。") -> dict:
    resp = client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": prompt},
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


class TrackingLLM(MockLLMClient):
    """Mock that records calls so tests can assert Extractor was/was-not invoked."""

    def __init__(self) -> None:
        self.json_calls: list[dict[str, Any]] = []
        self.stream_calls: list[dict[str, Any]] = []

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        self.json_calls.append({"system": system, "user": user})
        return super().complete_json(system=system, user=user, schema=schema, **kwargs)

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):  # type: ignore[override]
        self.stream_calls.append({"system": system, "user": user})
        return super().complete_stream(system=system, user=user, **kwargs)


def test_import_runs_extractor_by_default(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    draft = "雨夜山洞里，林夕摸到一枚带血的铜钱，心头一沉。"

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": draft},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["chapter"]["status"] == "finalized"
    assert body["chapter"]["source"] == "imported"
    assert body["chapter"]["draft_text"] == draft
    # Extractor (mock) sets summary + adds timeline events + updates live_fields.
    assert body["chapter"]["summary"]
    assert body["updated_character_ids"] == [character["id"]]
    assert len(body["added_event_ids"]) == 1

    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert timeline["items"][0]["event_text"] == "在山洞中发现带血铜钱。"
    updated = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert updated["live_fields"]["current_status"] == "带着铜钱离开山洞"


def test_import_skips_extractor_when_flag_off(client, auth_headers):
    tracker = TrackingLLM()
    # M-1: /import is wired to get_extractor_llm_client; override all of them
    # so the tracker reliably observes (or not observes) the call.
    override_all_llm_clients(lambda: tracker)

    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    draft = "用户自己写的章节正文。"

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": draft, "summary": "用户给的摘要。", "run_extractor": False},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["chapter"]["status"] == "finalized"
    assert body["chapter"]["source"] == "imported"
    assert body["chapter"]["draft_text"] == draft
    assert body["chapter"]["summary"] == "用户给的摘要。"
    assert body["updated_character_ids"] == []
    assert body["added_event_ids"] == []
    # Extractor must not have been called.
    assert tracker.json_calls == []
    assert tracker.stream_calls == []
    # No timeline events added.
    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert timeline["items"] == []
    # Character live_fields untouched.
    char_after = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert char_after["live_fields"]["current_status"] == "调查失踪案"


def test_import_rejects_finalized_chapter(client, auth_headers):
    book, _ = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"], prompt="林夕在山洞找到线索。")
    # Drive it through the full agent flow to reach finalized.
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as r:
        _ = "".join(r.iter_text())
    client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "新文本", "run_extractor": False},
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"


def test_import_overrides_title_when_provided(client, auth_headers):
    book, _ = _seed_book_character(client, auth_headers)
    # Create with a starting title.
    raw = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "起初", "title": "原始标题"},
    )
    chapter = raw.json()
    assert chapter["title"] == "原始标题"

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "正文。", "title": "新标题", "run_extractor": False},
    )
    assert resp.status_code == 200
    assert resp.json()["chapter"]["title"] == "新标题"


def test_import_keeps_title_when_not_provided(client, auth_headers):
    book, _ = _seed_book_character(client, auth_headers)
    raw = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "起初", "title": "保留我"},
    )
    chapter = raw.json()

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "正文。", "run_extractor": False},
    )
    assert resp.status_code == 200
    assert resp.json()["chapter"]["title"] == "保留我"


def test_import_requires_auth(client):
    # Need a chapter id; create one with auth, then try import without.
    # Quick path: seed with auth via fixture-less call would fail, so we use
    # the auth_headers fixture indirectly by reaching into the dependency.
    # Simpler: just call against a bogus id — missing auth must short-circuit
    # before we ever reach the not_found check.
    resp = client.post(
        "/api/v1/chapters/00000000-0000-0000-0000-000000000000/import",
        json={"draft_text": "x", "run_extractor": False},
    )
    assert resp.status_code == 401
    assert resp.json()["error"]["kind"] == "unauthorized"


def test_import_from_prompt_ready_state(client, auth_headers):
    """Mid-flow import: chapter already has structured_prompt — import still works."""
    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"], prompt="林夕在山洞找到线索。")
    # Advance to prompt_ready.
    expanded = client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers).json()
    assert expanded["status"] == "prompt_ready"

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "雨夜山洞里，林夕摸到一枚带血的铜钱。", "run_extractor": True},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["chapter"]["status"] == "finalized"
    assert body["chapter"]["source"] == "imported"


def test_import_from_draft_ready_state(client, auth_headers, session_factory):
    """Late-flow import: Writer already wrote a draft (status=draft_ready),
    user wants to discard it and paste their own version instead.

    Locks the plan §5.A.4 white-list — draft_ready stays allowed after the
    A-1 reviewer-driven tightening that removed 'writing' from it."""
    from app.models.chapter import Chapter

    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])

    # Force-flip to draft_ready (writer SSE path is too heavy to drive here).
    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "draft_ready"
        row.draft_text = "（Agent 之前写的稿子，将被覆盖。）"
        session.commit()

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "雨夜山洞里，林夕摸到一枚带血的铜钱。", "run_extractor": True},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["chapter"]["status"] == "finalized"
    assert body["chapter"]["source"] == "imported"
    assert body["chapter"]["draft_text"].startswith("雨夜山洞")


def test_import_rejects_writing_state(client, auth_headers, session_factory):
    """Lock the post-A-1-review contract: import is NOT allowed while the
    chapter is mid-SSE-stream (status='writing'). The SSE writer worker
    would otherwise race the import path and overwrite draft_text when it
    finishes."""
    from app.models.chapter import Chapter

    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])

    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "writing"
        session.commit()

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "导入应该被拒。", "run_extractor": False},
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"
