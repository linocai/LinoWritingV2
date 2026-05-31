from __future__ import annotations

import json
from typing import Any

from app.llm.errors import LLMError
from tests.conftest import MockLLMClient, override_all_llm_clients


# --- helpers ---------------------------------------------------------------


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
            "frozen_fields": {"core_traits": "谨慎、敏锐", "background": "退役的痕迹追踪员"},
            "live_fields": {"current_status": "调查失踪案"},
        },
    ).json()
    return book, character


def _new_chapter(client, auth_headers, book_id: str, prompt: str = "提取测试。") -> dict:
    resp = client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": prompt},
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _import_finalized(client, auth_headers, chapter_id: str, draft: str, summary: str | None = None) -> dict:
    """Land a chapter into ``finalized`` with ``draft_text`` but WITHOUT running
    the extractor (run_extractor=False) — the v0.9.3 §5.DI import behaviour.
    This is the precondition for the manual /extract endpoint."""
    payload: dict[str, Any] = {"draft_text": draft, "run_extractor": False}
    if summary is not None:
        payload["summary"] = summary
    resp = client.post(
        f"/api/v1/chapters/{chapter_id}/import",
        headers=auth_headers,
        json=payload,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["chapter"]["status"] == "finalized"
    return body["chapter"]


class FailingExtractorLLM(MockLLMClient):
    """Extractor whose ``complete_json`` blows up — simulates an upstream LLM
    failure during extraction (case ⑤)."""

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        context = json.loads(user)
        # Expander prompt path (build context) is fine; only the extractor
        # output call should fail. The /extract endpoint never calls expander,
        # but keep the guard symmetric with other tests for safety.
        if "all_characters" in context:
            return super().complete_json(system=system, user=user, schema=schema, **kwargs)
        raise LLMError("extractor exploded", retryable=False)


# --- ① finalized + draft_text + mock extractor → 200, ids + timeline -------


def test_extract_happy_path_builds_timeline(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    draft = "雨夜山洞里，林夕摸到一枚带血的铜钱，心头一沉。"
    _import_finalized(client, auth_headers, chapter["id"], draft)

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/extract",
        headers=auth_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # Chapter stays finalized; draft_text preserved; summary written by extractor.
    assert body["chapter"]["status"] == "finalized"
    assert body["chapter"]["draft_text"] == draft
    assert body["chapter"]["summary"]
    assert body["updated_character_ids"] == [character["id"]]
    assert len(body["added_event_ids"]) == 1

    # Timeline event + live_fields actually landed.
    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert len(timeline["items"]) == 1
    assert timeline["items"][0]["event_text"] == "在山洞中发现带血铜钱。"
    updated = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert updated["live_fields"]["current_status"] == "带着铜钱离开山洞"


# --- ② two extractions in a row → timeline not duplicated ------------------


def test_extract_twice_does_not_duplicate_timeline(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    draft = "雨夜山洞里，林夕摸到一枚带血的铜钱。"
    _import_finalized(client, auth_headers, chapter["id"], draft)

    first = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert first.status_code == 200, first.text
    second = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert second.status_code == 200, second.text

    # Old events were deleted before the second extraction → exactly one event,
    # not two. The added_event_ids from the second call are the only survivors.
    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert len(timeline["items"]) == 1
    assert len(second.json()["added_event_ids"]) == 1
    # Still finalized after the repeat.
    assert second.json()["chapter"]["status"] == "finalized"


# --- ③ non-finalized states → 409 -----------------------------------------


def test_extract_rejects_draft_state(client, auth_headers):
    book, _ = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])  # status == draft
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["kind"] == "conflict"


def test_extract_rejects_draft_ready_state(client, auth_headers, session_factory):
    from app.models.chapter import Chapter

    book, _ = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "draft_ready"
        row.draft_text = "已就绪的初稿。"
        session.commit()

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["kind"] == "conflict"


def test_extract_rejects_writing_state(client, auth_headers, session_factory):
    from app.models.chapter import Chapter

    book, _ = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "writing"
        row.draft_text = "写作中。"
        session.commit()

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["kind"] == "conflict"


# --- ④ finalized but empty draft_text → 409 no_draft_to_extract ------------


def test_extract_rejects_empty_draft(client, auth_headers, session_factory):
    from app.models.chapter import Chapter

    book, _ = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    # Finalized with whitespace-only draft_text → no extractable body.
    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "finalized"
        row.draft_text = "   \n  "
        session.commit()

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert resp.status_code == 409, resp.text
    body = resp.json()
    assert body["error"]["kind"] == "conflict"
    assert body["error"]["message"] == "本章没有正文可提取"


# --- ⑤ extractor LLM raises → error surfaced, draft_text + status preserved -


def test_extract_llm_failure_preserves_chapter(client, auth_headers):
    book, character = _seed_book_character(client, auth_headers)
    chapter = _new_chapter(client, auth_headers, book["id"])
    draft = "雨夜山洞里，林夕摸到一枚带血的铜钱。"
    _import_finalized(client, auth_headers, chapter["id"], draft)

    # --- First extract SUCCEEDS (default MockLLMClient) so the chapter has a
    # real timeline event + updated live_fields. Without this the failure-path
    # assertions below would be vacuous: a chapter with no prior timeline passes
    # "timeline unchanged" even if pre-delete + rollback were broken. (reviewer
    # 🟡#3 — only a non-empty starting timeline truly locks the contract that
    # the pre-delete and the rollback live in the same transaction, so a failed
    # re-extract restores the OLD timeline rather than wiping it.)
    first = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    assert first.status_code == 200, first.text
    assert len(first.json()["added_event_ids"]) >= 1

    timeline_before = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()["items"]
    assert len(timeline_before) >= 1, "first extract must build at least one event"
    char_before = client.get(
        f"/api/v1/characters/{character['id']}", headers=auth_headers
    ).json()
    live_before = char_before["live_fields"]

    # --- Second extract FAILS: swap in a failing extractor. The endpoint
    # pre-deletes the timeline, then the extractor blows up → rollback must
    # restore the timeline created by the first run (same tx).
    override_all_llm_clients(lambda: FailingExtractorLLM())

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/extract", headers=auth_headers)
    # LLMError → i18n_upstream("llm_generic") → 502 upstream envelope.
    assert resp.status_code == 502, resp.text
    assert resp.json()["error"]["kind"] == "upstream"

    # Chapter draft_text + status untouched.
    after = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert after["status"] == "finalized"
    assert after["draft_text"] == draft

    # Timeline is STILL exactly the first run's event(s) — count and content
    # unchanged. If pre-delete weren't rolled back together with the failed
    # apply, this would be empty (events wiped) instead.
    timeline_after = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()["items"]
    assert len(timeline_after) == len(timeline_before)
    assert [e["id"] for e in timeline_after] == [e["id"] for e in timeline_before]
    assert [e["event_text"] for e in timeline_after] == [
        e["event_text"] for e in timeline_before
    ]

    # Character live_fields are exactly what the first extract left — not the
    # pre-import "调查失踪案" and not wiped.
    char_after = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert char_after["live_fields"] == live_before
