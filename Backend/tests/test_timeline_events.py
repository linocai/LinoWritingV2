"""Tests for ``PATCH`` / ``DELETE /api/v1/timeline_events/{id}`` (v0.7 §5.C).

Seeds a book → character → chapter → finalize via the same MockLLMClient path
the rest of the suite uses, then pokes the new endpoints directly. The
MockLLMClient extractor reliably produces exactly one timeline event
("在山洞中发现带血铜钱。") so every test starts with a known event_id and
event_text.
"""
from __future__ import annotations

from datetime import datetime


def _seed_event(client, auth_headers) -> tuple[dict, dict, dict]:
    """Walk the full agent flow once and return (book, character, event).

    The event is the single TimelineEvent that ``MockLLMClient`` writes during
    extraction; see ``Backend/tests/conftest.py``. Returning ``event`` saves
    each test from re-fetching the timeline.
    """
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "时间线", "cover_color": "#222222"},
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎"},
            "live_fields": {"current_status": "调查"},
        },
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "夜雨", "user_prompt": "林夕在山洞找到关键线索。"},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    with client.stream(
        "POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers
    ) as resp:
        for _ in resp.iter_text():
            pass
    client.post(f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers)
    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert timeline["items"], "MockLLMClient extractor must produce at least one event"
    return book, character, timeline["items"][0]


# ---------------------------------------------------------------------------
# PATCH
# ---------------------------------------------------------------------------


def test_patch_event_text_sets_edited_at(client, auth_headers):
    _, _, event = _seed_event(client, auth_headers)
    assert event["edited_at"] is None, "freshly Extractor-written rows must have edited_at == NULL"

    response = client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={"event_text": "在山洞中拾起一枚生锈的铜钱。"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["event_text"] == "在山洞中拾起一枚生锈的铜钱。"
    assert body["event_type"] == event["event_type"], "PATCH must not silently rewrite event_type"
    assert body["edited_at"] is not None
    # ISO8601 sanity — should be parseable.
    datetime.fromisoformat(body["edited_at"].replace("Z", "+00:00"))


def test_patch_event_type_only(client, auth_headers):
    _, _, event = _seed_event(client, auth_headers)
    response = client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={"event_type": "secret_learned"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["event_type"] == "secret_learned"
    assert body["event_text"] == event["event_text"], "PATCH event_type must not touch event_text"
    assert body["edited_at"] is not None


def test_patch_empty_body_returns_422(client, auth_headers):
    _, _, event = _seed_event(client, auth_headers)
    response = client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={},
    )
    assert response.status_code == 422
    assert response.json()["error"]["kind"] == "validation"


def test_patch_ignores_disallowed_fields(client, auth_headers):
    """character_id / chapter_id / book_id / id must not be mutable.

    Pydantic with default ``extra='ignore'`` drops the unknown keys at parse
    time; the router-level allowlist is a defence-in-depth re-assert. We poke
    the endpoint with garbage on these fields and confirm the row's identity
    columns are untouched.
    """
    book, character, event = _seed_event(client, auth_headers)
    response = client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={
            "event_text": "改了文本",
            "character_id": "00000000-0000-0000-0000-000000000000",
            "chapter_id": "00000000-0000-0000-0000-000000000000",
            "book_id": "00000000-0000-0000-0000-000000000000",
            "id": "00000000-0000-0000-0000-000000000000",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == event["id"]
    assert body["character_id"] == character["id"]
    assert body["chapter_id"] == event["chapter_id"]
    assert body["book_id"] == book["id"]
    assert body["event_text"] == "改了文本"


def test_patch_nonexistent_event_returns_404(client, auth_headers):
    response = client.patch(
        "/api/v1/timeline_events/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
        json={"event_text": "any"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["kind"] == "not_found"


def test_patch_without_auth_returns_401(client):
    response = client.patch(
        "/api/v1/timeline_events/00000000-0000-0000-0000-000000000000",
        json={"event_text": "any"},
    )
    assert response.status_code == 401
    assert response.json()["error"]["kind"] == "unauthorized"


def test_patch_invalid_event_type_returns_422(client, auth_headers):
    """Defence around the Literal-typed enum — sending a garbage event_type
    must 422 rather than silently storing it."""
    _, _, event = _seed_event(client, auth_headers)
    response = client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={"event_type": "totally-not-a-real-type"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["kind"] == "validation"


def test_patch_allowlist_constant_only_contains_safe_fields():
    """Direct guard so the allowlist gets reviewed any time it changes."""
    from app.routers.timeline_events import PATCHABLE_TIMELINE_EVENT_FIELDS

    assert PATCHABLE_TIMELINE_EVENT_FIELDS == frozenset({"event_text", "event_type"})


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------


def test_delete_event_succeeds_and_disappears_from_timeline(client, auth_headers):
    _, character, event = _seed_event(client, auth_headers)
    response = client.delete(
        f"/api/v1/timeline_events/{event['id']}", headers=auth_headers
    )
    assert response.status_code == 204
    assert response.content == b""

    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    assert all(item["id"] != event["id"] for item in timeline["items"])


def test_delete_nonexistent_event_returns_404(client, auth_headers):
    response = client.delete(
        "/api/v1/timeline_events/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
    )
    assert response.status_code == 404
    assert response.json()["error"]["kind"] == "not_found"


def test_delete_without_auth_returns_401(client):
    response = client.delete(
        "/api/v1/timeline_events/00000000-0000-0000-0000-000000000000",
    )
    assert response.status_code == 401
    assert response.json()["error"]["kind"] == "unauthorized"


# ---------------------------------------------------------------------------
# /timeline read-back surfaces edited_at
# ---------------------------------------------------------------------------


def test_timeline_list_surfaces_edited_at_after_patch(client, auth_headers):
    """Regression guard: ``GET /characters/{id}/timeline`` must include
    ``edited_at`` so the frontend's "已编辑" marker stays consistent across
    a reload."""
    _, character, event = _seed_event(client, auth_headers)
    client.patch(
        f"/api/v1/timeline_events/{event['id']}",
        headers=auth_headers,
        json={"event_text": "更新后的文本"},
    )
    timeline = client.get(
        f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
    ).json()
    edited_row = next(item for item in timeline["items"] if item["id"] == event["id"])
    assert edited_row["edited_at"] is not None
    assert edited_row["event_text"] == "更新后的文本"
