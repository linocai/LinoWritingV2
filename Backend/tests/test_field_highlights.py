"""Phase B-fld (§5.B) — field-level dot indicator backend tests.

Covers:
- Extractor mock returns patch_keys → apply writes pending_field_highlights
  for the corresponding keys (with ISO timestamps).
- New highlights merge with existing ones (multi-chapter accumulation).
- PATCH live_fields clears highlights for the keys edited.
- PATCH frozen_fields / author_notes does NOT touch highlights (Extractor
  never writes those, so they can't be highlighted in the first place).
- LLM-reported ``patch_keys`` disagreeing with ``live_fields_patch.keys()``:
  server trusts ``patch.keys()`` as authoritative.
- Legacy character (no pending_field_highlights row) reads back as ``{}``.
"""
from __future__ import annotations

from typing import Any

from app.agents.extractor import EXTRACTOR_SCHEMA
from app.models.character import Character
from app.services.extractor_apply import apply_extractor_output


def _book(client, auth_headers) -> dict:
    return client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "长夜"},
    ).json()


def _character(client, auth_headers, book_id: str, *, live_fields: dict | None = None) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "live_fields": live_fields or {"current_status": "调查失踪案"},
        },
    ).json()


def _new_chapter(client, auth_headers, book_id: str) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": "测试章节"},
    ).json()


# ---------- 1. Extractor → highlights happy path ----------

def test_extractor_writes_pending_field_highlights(client, auth_headers, db_session):
    """End-to-end via /finalize: after Extractor runs (conftest MockLLM
    returns ``live_fields_patch={'current_status': ...}``), the character
    must have a non-empty pending_field_highlights with the patched key.

    The conftest mock returns ``live_fields_patch={'current_status': ...}``
    without a ``patch_keys`` array — verifying the fallback path where
    ``patch.keys()`` is the sole source of truth.
    """
    from app.models.chapter import Chapter

    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])
    chapter = _new_chapter(client, auth_headers, book["id"])

    # Walk the chapter through the agent flow → finalize.
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as r:
        _ = "".join(r.iter_text())
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)
    assert resp.status_code == 200, resp.text

    fetched = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    highlights = fetched["pending_field_highlights"]
    assert "current_status" in highlights, f"expected current_status in highlights, got {highlights!r}"
    # The value should be an ISO 8601 timestamp string.
    assert isinstance(highlights["current_status"], str)
    assert "T" in highlights["current_status"]  # ISO 8601 separator


# ---------- 2. New highlights merge with existing ones ----------

def test_pending_highlights_merge_across_chapters(client, auth_headers, db_session, session_factory):
    """If chapter A's Extractor highlights `current_status` and chapter B's
    highlights `knowledge`, the character should end up with BOTH keys
    flagged (unseen flags accumulate until the user edits the field).
    """
    from app.models.chapter import Chapter

    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    # Manually pre-seed pending_field_highlights with an "old" key
    # (simulating a prior unseen highlight from a previous chapter).
    with session_factory() as session:
        row = session.get(Character, character["id"])
        row.pending_field_highlights = {"knowledge": "2026-05-24T10:00:00+00:00"}
        session.commit()

    # Now drive an Extractor pass that touches `current_status`.
    chapter = _new_chapter(client, auth_headers, book["id"])
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as r:
        _ = "".join(r.iter_text())
    client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)

    fetched = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    highlights = fetched["pending_field_highlights"]
    # Both old and new keys must be present.
    assert "knowledge" in highlights
    assert "current_status" in highlights
    # Old timestamp preserved.
    assert highlights["knowledge"] == "2026-05-24T10:00:00+00:00"


# ---------- 3. PATCH live_fields clears matching highlights ----------

def test_patch_live_fields_clears_corresponding_highlights(client, auth_headers, session_factory):
    """When the user PATCHes the character's live_fields, every key in the
    new live_fields payload has its highlight removed (the canonical
    "user has seen this" signal).
    """
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    # Seed two highlighted keys.
    with session_factory() as session:
        row = session.get(Character, character["id"])
        row.pending_field_highlights = {
            "current_status": "2026-05-25T12:00:00+00:00",
            "knowledge": "2026-05-25T12:00:00+00:00",
        }
        session.commit()

    # User edits current_status via PATCH (whole-object replace).
    resp = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"live_fields": {"current_status": "新的状态", "knowledge": "现有知识"}},
    )
    assert resp.status_code == 200
    # Both keys present in the new payload → both highlights cleared.
    assert resp.json()["pending_field_highlights"] == {}


def test_patch_live_fields_with_partial_keys_clears_only_those(client, auth_headers, session_factory):
    """If the new live_fields payload omits a previously-highlighted key
    (whole-object replace removes it from live_fields), the highlight is
    also cleared since the key no longer exists on the character at all.
    The remaining highlights (for keys NOT in the new payload AND NOT
    previously highlighted-and-then-removed) survive."""
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    with session_factory() as session:
        row = session.get(Character, character["id"])
        row.pending_field_highlights = {
            "current_status": "2026-05-25T12:00:00+00:00",
            "knowledge": "2026-05-25T12:00:00+00:00",
            "secret": "2026-05-25T12:00:00+00:00",
        }
        session.commit()

    # PATCH only touches current_status — other keys' highlights survive.
    resp = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"live_fields": {"current_status": "新状态"}},
    )
    assert resp.status_code == 200
    highlights = resp.json()["pending_field_highlights"]
    assert "current_status" not in highlights
    # Keys not in the new payload still flagged (the canonical "still unseen").
    assert "knowledge" in highlights
    assert "secret" in highlights


# ---------- 4. PATCH frozen / author_notes does NOT clear highlights ----------

def test_patch_frozen_fields_does_not_touch_highlights(client, auth_headers, session_factory):
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    with session_factory() as session:
        row = session.get(Character, character["id"])
        row.pending_field_highlights = {"current_status": "2026-05-25T12:00:00+00:00"}
        session.commit()

    resp = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"frozen_fields": {"core_traits": "果决"}},
    )
    assert resp.status_code == 200
    assert resp.json()["pending_field_highlights"] == {
        "current_status": "2026-05-25T12:00:00+00:00"
    }


def test_patch_author_notes_does_not_touch_highlights(client, auth_headers, session_factory):
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    with session_factory() as session:
        row = session.get(Character, character["id"])
        row.pending_field_highlights = {"knowledge": "2026-05-25T12:00:00+00:00"}
        session.commit()

    resp = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"author_notes": {"motivation": "救妹妹"}},
    )
    assert resp.status_code == 200
    assert resp.json()["pending_field_highlights"] == {
        "knowledge": "2026-05-25T12:00:00+00:00"
    }


# ---------- 5. Server uses patch.keys() as source of truth ----------

def test_apply_extractor_output_trusts_patch_keys_over_llm_declaration(
    client, auth_headers, db_session
):
    """Plan §5.B: if the LLM's declared ``patch_keys`` disagrees with the
    actual ``live_fields_patch.keys()``, the server takes ``patch.keys()``
    as authoritative (defence against LLM hallucination).
    """
    from app.models.chapter import Chapter

    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"])

    # Direct service-layer call so we control what the "Extractor output"
    # looks like — no need to mock the LLM.
    with db_session.no_autoflush:
        chapter_row = Chapter(
            book_id=book["id"],
            index=99,
            title="测试章",
            user_prompt="测试",
            status="draft_ready",
            source="agent",
        )
        db_session.add(chapter_row)
        db_session.flush()

        bad_output: dict[str, Any] = {
            "summary": "本章发生了一些事。",
            "timeline_events": [],
            "character_updates": [
                {
                    "character_id": character["id"],
                    # LLM lies: says it patched "knowledge" and "abilities",
                    # but actually only patches "current_status".
                    "patch_keys": ["knowledge", "abilities"],
                    "live_fields_patch": {"current_status": "新状态"},
                }
            ],
        }
        apply_extractor_output(db_session, chapter_row, bad_output)
        db_session.commit()

    fetched = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    highlights = fetched["pending_field_highlights"]
    # Only the truly-patched key flagged; the lied-about keys are NOT.
    assert "current_status" in highlights
    assert "knowledge" not in highlights
    assert "abilities" not in highlights


# ---------- 6. Legacy / ORM default ----------

def test_orm_default_supplies_empty_pending_field_highlights(client, auth_headers, db_session):
    """A pre-B-fld character row (inserted without specifying
    pending_field_highlights) must read back as ``{}``. Same pattern as
    L-1 author_notes — both the SQLAlchemy default and the migration
    server_default cover this."""
    book = _book(client, auth_headers)
    legacy = Character(book_id=book["id"], name="旧角色")
    db_session.add(legacy)
    db_session.commit()
    db_session.refresh(legacy)

    fetched = client.get(f"/api/v1/characters/{legacy.id}", headers=auth_headers)
    assert fetched.status_code == 200
    assert fetched.json()["pending_field_highlights"] == {}


# ---------- 7. Schema lock ----------

def test_extractor_schema_includes_patch_keys_slot():
    """Lock the contract that EXTRACTOR_SCHEMA exposes patch_keys to the
    LLM — guards against a future refactor accidentally removing it."""
    char_update_schema = (
        EXTRACTOR_SCHEMA["properties"]["character_updates"]["items"]["properties"]
    )
    assert "patch_keys" in char_update_schema
    assert char_update_schema["patch_keys"]["type"] == "array"
    assert char_update_schema["patch_keys"]["items"]["type"] == "string"


def test_character_patch_does_not_expose_pending_field_highlights():
    """Lock the schema decision in §5.B: CharacterPatch does NOT include
    pending_field_highlights — clearing is the side effect of editing
    live_fields, not a separately-PATCHable field. If a future
    contributor exposes it, this regression test fires.
    """
    from app.schemas.character import CharacterPatch

    fields = CharacterPatch.model_fields
    assert "pending_field_highlights" not in fields, (
        "pending_field_highlights must not be PATCHable directly; "
        "clearing happens automatically when live_fields is PATCHed"
    )
