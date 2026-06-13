from __future__ import annotations

# v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §5.1) — book outline ingest /
# get / patch. The outline is a singleton per book (upsert), never runs an
# LLM, and PATCH whitelists raw_text only.


def _make_book(client, auth_headers) -> str:
    resp = client.post("/api/v1/books", headers=auth_headers, json={"title": "长夜"})
    assert resp.status_code == 201
    return resp.json()["id"]


def test_outline_ingest_get_and_upsert(client, auth_headers):
    book_id = _make_book(client, auth_headers)

    # GET before any ingest → null
    empty = client.get(f"/api/v1/books/{book_id}/outline", headers=auth_headers)
    assert empty.status_code == 200
    assert empty.json()["outline"] is None

    # First ingest creates the row.
    first = client.post(
        f"/api/v1/books/{book_id}/outline/ingest",
        headers=auth_headers,
        json={"raw_text": "第一稿大纲：少年离乡。"},
    )
    assert first.status_code == 200
    outline = first.json()["outline"]
    assert outline["book_id"] == book_id
    assert outline["raw_text"] == "第一稿大纲：少年离乡。"
    outline_id = outline["id"]

    # GET returns the persisted outline.
    fetched = client.get(f"/api/v1/books/{book_id}/outline", headers=auth_headers)
    assert fetched.status_code == 200
    assert fetched.json()["outline"]["raw_text"] == "第一稿大纲：少年离乡。"

    # Second ingest UPSERTS the same singleton row (id stable, text replaced).
    second = client.post(
        f"/api/v1/books/{book_id}/outline/ingest",
        headers=auth_headers,
        json={"raw_text": "第二稿大纲：少年归来。"},
    )
    assert second.status_code == 200
    upserted = second.json()["outline"]
    assert upserted["id"] == outline_id  # same row, not a new outline
    assert upserted["raw_text"] == "第二稿大纲：少年归来。"

    # Confirm there is still exactly one outline (singleton).
    again = client.get(f"/api/v1/books/{book_id}/outline", headers=auth_headers)
    assert again.json()["outline"]["id"] == outline_id


def test_outline_patch_whitelist(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    client.post(
        f"/api/v1/books/{book_id}/outline/ingest",
        headers=auth_headers,
        json={"raw_text": "原始大纲。"},
    )

    # PATCH raw_text (the only whitelisted field) takes effect.
    patched = client.patch(
        f"/api/v1/books/{book_id}/outline",
        headers=auth_headers,
        json={"raw_text": "手改后的大纲。"},
    )
    assert patched.status_code == 200
    assert patched.json()["outline"]["raw_text"] == "手改后的大纲。"

    # Unknown keys are ignored (whitelist), raw_text unchanged by them.
    ignore = client.patch(
        f"/api/v1/books/{book_id}/outline",
        headers=auth_headers,
        json={"id": "hacked", "book_id": "hacked", "created_at": "2000-01-01T00:00:00Z"},
    )
    assert ignore.status_code == 200
    body = ignore.json()["outline"]
    assert body["book_id"] == book_id  # FK not hijacked
    assert body["id"] != "hacked"
    assert body["raw_text"] == "手改后的大纲。"  # untouched


def test_outline_patch_creates_when_missing(client, auth_headers):
    # PATCH before any ingest upserts so the author can author straight from
    # the edit surface.
    book_id = _make_book(client, auth_headers)
    resp = client.patch(
        f"/api/v1/books/{book_id}/outline",
        headers=auth_headers,
        json={"raw_text": "直接手写的大纲。"},
    )
    assert resp.status_code == 200
    assert resp.json()["outline"]["raw_text"] == "直接手写的大纲。"


def test_outline_missing_book_is_404(client, auth_headers):
    missing = client.get("/api/v1/books/nonexistent/outline", headers=auth_headers)
    assert missing.status_code == 404
    assert missing.json()["error"]["kind"] == "not_found"

    ingest = client.post(
        "/api/v1/books/nonexistent/outline/ingest",
        headers=auth_headers,
        json={"raw_text": "x"},
    )
    assert ingest.status_code == 404
