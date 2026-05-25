"""Tests for the PATCH /chapters/{id} field allowlist (§5.P.1 F).

ChapterPatch schema already restricts inputs at the Pydantic layer, but
the router applies a second allowlist on assignment so that adding a new
ChapterPatch field later doesn't silently create a mass-assignment hole
for protected attributes (status, source, index, book_id).
"""
from __future__ import annotations


def _seed_chapter(client, auth_headers):
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "Patch Test", "cover_color": "#222222"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "原 prompt"},
    ).json()
    return book, chapter


def test_patch_accepts_whitelisted_fields(client, auth_headers):
    _, chapter = _seed_chapter(client, auth_headers)
    response = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={
            "title": "新标题",
            "user_prompt": "新 prompt",
            "draft_text": "正文",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["title"] == "新标题"
    assert body["user_prompt"] == "新 prompt"
    assert body["draft_text"] == "正文"


def test_patch_ignores_status_field(client, auth_headers):
    """Even if a future ChapterPatch schema regression let `status` through,
    the router-level allowlist must prevent the assignment."""
    _, chapter = _seed_chapter(client, auth_headers)
    original_status = chapter["status"]
    # Pydantic with default extra='ignore' will drop the unknown field
    # at parse time. We assert via the actual GET that the status was
    # NOT mutated.
    response = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"status": "finalized", "title": "new"},
    )
    assert response.status_code == 200
    refreshed = client.get(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
    ).json()
    assert refreshed["status"] == original_status
    assert refreshed["title"] == "new"


def test_patch_ignores_source_field(client, auth_headers):
    _, chapter = _seed_chapter(client, auth_headers)
    original_source = chapter["source"]
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"source": "imported"},
    )
    refreshed = client.get(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
    ).json()
    assert refreshed["source"] == original_source


def test_patch_ignores_index_and_book_id(client, auth_headers):
    book, chapter = _seed_chapter(client, auth_headers)
    original_index = chapter["index"]
    original_book = chapter["book_id"]
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={
            "index": 999,
            "book_id": "00000000-0000-0000-0000-000000000000",
            "title": "still works",
        },
    )
    refreshed = client.get(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
    ).json()
    assert refreshed["index"] == original_index
    assert refreshed["book_id"] == original_book
    assert refreshed["title"] == "still works"


def test_patch_allowlist_constant_only_contains_safe_fields():
    """Direct guard so the allowlist is reviewed any time it changes."""
    from app.routers.chapters import PATCHABLE_CHAPTER_FIELDS

    assert PATCHABLE_CHAPTER_FIELDS == frozenset(
        {"title", "user_prompt", "structured_prompt", "draft_text"}
    )
