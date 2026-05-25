"""Phase N (§5.N) — Chinese error message templates.

Locks the user-facing copy that surfaces in the iOS/macOS Toast. The
envelope shape is unchanged (still ``{error: {kind, message, details}}``);
only ``message`` flips from English to Chinese for errors an author
actually sees during normal use.

Out of scope here (kept English on purpose):
- Pydantic ``RequestValidationError`` (kind=validation) — debug-only
- ``IntegrityError`` (kind=conflict, "Database constraint conflict") — debug
- Generic 500 ``Internal server error`` — debug
See ``app/errors.py``'s template registry comment for the scope rule.
"""
from __future__ import annotations

from typing import Any

from app.errors import (
    AGENT_ROLE_CN,
    CHAPTER_ACTION_CN,
    CHAPTER_STATUS_CN,
    i18n_conflict,
    i18n_not_found,
    i18n_upstream,
    render_message,
)


# --- 1. Template registry — direct unit tests ------------------------------


def test_render_message_known_template_substitutes_vars() -> None:
    msg = render_message(
        "conflict",
        "chapter_status_invalid_action",
        status_cn="写作",
        action_cn="开始写作",
    )
    assert msg == "章节当前正在「写作」中，无法开始写作"


def test_render_message_unknown_key_falls_back_to_key_literal() -> None:
    # A typo at the call site degrades gracefully — no KeyError 500.
    msg = render_message("conflict", "this_key_does_not_exist", x="y")
    assert msg == "this_key_does_not_exist"


def test_render_message_missing_placeholder_returns_raw_template() -> None:
    # Forgetting to pass a placeholder var must not raise — return the
    # template so the developer notices the {var} in the surfaced message.
    msg = render_message("conflict", "chapter_status_invalid_action")
    assert "{status_cn}" in msg


def test_i18n_helpers_produce_correct_kind_and_status_code() -> None:
    conflict_err = i18n_conflict(
        "chapter_status_invalid_action",
        status_cn="写作",
        action_cn="开始写作",
    )
    assert conflict_err.kind == "conflict"
    assert conflict_err.status_code == 409
    assert "写作" in conflict_err.message

    not_found_err = i18n_not_found("chapter")
    assert not_found_err.kind == "not_found"
    assert not_found_err.status_code == 404
    assert not_found_err.message == "章节不存在，可能已被删除"

    upstream_err = i18n_upstream("llm_no_active_key", retryable=False)
    assert upstream_err.kind == "upstream"
    assert upstream_err.status_code == 502
    assert upstream_err.retryable is False


# --- 2. Chapter state machine — end-to-end through HTTP envelope -----------


def _seed_book_character(client, auth_headers) -> tuple[dict, dict]:
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "i18n 测试书", "cover_color": "#222"},
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎"},
            "live_fields": {"current_status": "调查失踪案"},
        },
    ).json()
    return book, character


def _make_chapter(client, auth_headers, book_id: str) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": "本章意图。"},
    ).json()


def test_finalize_in_draft_returns_chinese_conflict_message(client, auth_headers) -> None:
    """finalize requires status=draft_ready. Calling it on a fresh draft
    must return a 409 envelope whose ``message`` is Chinese, with the raw
    English status/action preserved in ``details`` for programmatic use."""
    book, _ = _seed_book_character(client, auth_headers)
    chapter = _make_chapter(client, auth_headers, book["id"])

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/finalize",
        headers=auth_headers,
    )
    assert resp.status_code == 409
    body = resp.json()
    assert body["error"]["kind"] == "conflict"
    msg = body["error"]["message"]
    # Chinese-language assertion: the literal CN word for the current
    # status ('草稿') and the action ('定稿') must both appear.
    assert CHAPTER_STATUS_CN["draft"] in msg  # 草稿
    assert CHAPTER_ACTION_CN["finalize"] in msg  # 定稿
    assert "无法" in msg
    # details still carries raw codes for the frontend to branch on.
    assert body["error"]["details"]["status"] == "draft"
    assert body["error"]["details"]["action"] == "finalize"


def test_import_in_finalized_returns_chinese_conflict_message(client, auth_headers) -> None:
    """Plan §5.A.4 — finalized chapters cannot be re-imported. The 409
    surfaces a Chinese template (not 'Chapter status finalized cannot
    perform import')."""
    book, _ = _seed_book_character(client, auth_headers)
    chapter = _make_chapter(client, auth_headers, book["id"])

    # Drive the chapter to ``finalized`` via the normal flow.
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers
    ).status_code == 200
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers
    ).status_code == 200
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers
    ).status_code == 200

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "新导入的文本。"},
    )
    assert resp.status_code == 409
    msg = resp.json()["error"]["message"]
    assert CHAPTER_STATUS_CN["finalized"] in msg  # 已定稿
    assert CHAPTER_ACTION_CN["import"] in msg  # 导入正文


def test_write_in_writing_returns_chinese_conflict_message(client, auth_headers) -> None:
    """Reproduce the original pain point: 'Chapter status writing cannot
    perform write' → 章节当前正在「写作」中，无法开始写作.

    We push the chapter into ``writing`` directly via DB mutation so the
    second /write call hits the ensure_chapter_status guard cleanly
    without racing the SSE producer thread.
    """
    from sqlalchemy import select

    from app.db import get_db
    from app.main import app as fastapi_app
    from app.models.chapter import Chapter

    book, _ = _seed_book_character(client, auth_headers)
    chapter = _make_chapter(client, auth_headers, book["id"])

    # Move to prompt_ready first so we have something to legally write
    # against, then flip to 'writing' to simulate a stuck stream.
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers
    ).status_code == 200

    # Direct DB mutation: pull the session fixture out of the dependency
    # overrides and bump the row to status=writing.
    db_override = fastapi_app.dependency_overrides[get_db]
    db_iter = db_override()
    db = next(db_iter)
    row = db.scalars(select(Chapter).where(Chapter.id == chapter["id"])).one()
    row.status = "writing"
    db.commit()
    try:
        next(db_iter)
    except StopIteration:
        pass

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/write",
        headers=auth_headers,
    )
    assert resp.status_code == 409
    msg = resp.json()["error"]["message"]
    assert CHAPTER_STATUS_CN["writing"] in msg  # 写作
    assert CHAPTER_ACTION_CN["write"] in msg  # 开始写作


# --- 3. Resource-not-found 404 messages ------------------------------------


def test_chapter_not_found_returns_chinese_message(client, auth_headers) -> None:
    resp = client.get(
        "/api/v1/chapters/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["message"] == "章节不存在，可能已被删除"


def test_book_not_found_returns_chinese_message(client, auth_headers) -> None:
    resp = client.get(
        "/api/v1/books/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["message"] == "书籍不存在，可能已被删除"


def test_provider_key_not_found_returns_chinese_message(client, auth_headers) -> None:
    resp = client.patch(
        "/api/v1/provider_keys/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
        json={"key_label": "x"},
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["message"] == "未找到对应的 LLM Key，可能已被删除"


# --- 4. Provider key agent-role binding mismatch ---------------------------


def test_provider_key_agent_mismatch_returns_chinese_conflict(client, auth_headers) -> None:
    """A key pinned to ``agent_role=extractor`` cannot be activated for
    the writer slot. The Chinese template must name both Chinese role
    labels and drop the English 'Provider key is bound to a different
    agent_role' copy."""
    created = client.post(
        "/api/v1/provider_keys",
        headers=auth_headers,
        json={
            "key_label": "extractor-only",
            "provider_hint": "openai",
            "base_url": "https://api.openai.com/v1",
            "api_key": "sk-EXTR-1111",
            "model_name": "gpt-4o-mini",
            "agent_role": "extractor",
        },
    ).json()
    resp = client.put(
        "/api/v1/settings/active_key/writer",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    assert resp.status_code == 409
    body = resp.json()
    msg = body["error"]["message"]
    assert AGENT_ROLE_CN["extractor"] in msg
    assert AGENT_ROLE_CN["writer"] in msg
    # Programmatic details still carry raw codes.
    assert body["error"]["details"]["key_agent_role"] == "extractor"
    assert body["error"]["details"]["requested"] == "writer"


# --- 5. LLM "no active key" sentinel ---------------------------------------


def test_no_active_llm_key_message_is_chinese(client, auth_headers) -> None:
    """The factory's headline error (no key configured at all) flips to
    Chinese, with the legacy sentinel string preserved in details.code
    for backward-compatible programmatic handling."""
    from tests.conftest import clear_all_llm_overrides

    clear_all_llm_overrides()
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "无 key 测试", "cover_color": "#333"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "甲", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "提纲。"},
    ).json()

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand",
        headers=auth_headers,
    )
    assert resp.status_code == 502
    body = resp.json()
    assert body["error"]["kind"] == "upstream"
    assert body["error"]["message"] == "尚未配置可用的 LLM Key，请先到设置里添加并设为 active"
    # Sentinel kept for tests / future i18n switches.
    assert body["error"]["details"]["code"] == "no_active_llm_key"
