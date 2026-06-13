"""Tests for the v0.7 §5.F export endpoints.

Covers:
* book Markdown / plain-text bodies (title, world_setting, chapter order,
  separators)
* chapter Markdown / plain-text bodies
* ``include_drafts`` query semantics (default off → only finalized)
* error envelopes (404 not-found via i18n_not_found, 422 format=invalid,
  401 unauth)
* Content-Disposition header — both ASCII fallback and RFC 5987 encoded
  ``filename*`` for Chinese book/chapter titles
"""

from __future__ import annotations

from urllib.parse import quote


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------


def _seed_book_with_chapters(client, auth_headers, *, world: str | None = None):
    """Create a book + two chapters, finalize the first, leave the second
    as a plain draft. Returns ``(book, chapter1, chapter2)``.

    The first chapter's title is intentionally Chinese so we can assert
    the export bodies use the correct heading. The second is left
    untitled so we exercise the "no title" branch of ``_chapter_heading``.
    """
    book_payload = {"title": "夜雨长歌", "cover_color": "#222222"}
    if world is not None:
        book_payload["world_setting"] = world
    book = client.post("/api/v1/books", headers=auth_headers, json=book_payload).json()
    if world is not None:
        # ``world_setting`` is settable via PATCH only (BookCreate doesn't
        # expose it). Hop straight to PATCH so the seed isn't fragile.
        client.patch(
            f"/api/v1/books/{book['id']}",
            headers=auth_headers,
            json={"world_setting": world},
        )

    # The MockLLMClient extractor expects at least one character on the book
    # (see ``conftest.py:46``), otherwise finalize blows up with IndexError.
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎"},
            "live_fields": {"current_status": "调查"},
        },
    )

    # chapter 1 — finalize via the full Mock pipeline so it lands in
    # `finalized` state with a real draft_text.
    chapter1 = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "雨夜山洞", "user_prompt": "主角发现关键线索。"},
    ).json()
    client.post(f"/api/v1/chapters/{chapter1['id']}/expand", headers=auth_headers)
    with client.stream(
        "POST", f"/api/v1/chapters/{chapter1['id']}/write", headers=auth_headers
    ) as resp:
        for _ in resp.iter_text():
            pass
    client.post(f"/api/v1/chapters/{chapter1['id']}/finalize", headers=auth_headers)
    chapter1 = client.get(
        f"/api/v1/chapters/{chapter1['id']}", headers=auth_headers
    ).json()

    # chapter 2 — left as a raw draft (no title, no body).
    chapter2 = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "第二章草稿，未完成。"},
    ).json()

    return book, chapter1, chapter2


# ---------------------------------------------------------------------------
# Book export — Markdown
# ---------------------------------------------------------------------------


def test_export_book_markdown_default_omits_drafts(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "markdown"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")

    body = response.text
    # H1 carries the book title.
    assert body.startswith(f"# {book['title']}"), body[:80]
    # Finalized chapter (chapter1) shows up as a Markdown H2.
    assert f"## 第 {chapter1['index']} 章 · 雨夜山洞" in body
    # The draft chapter (chapter2) is excluded by default.
    assert "第 2 章" not in body
    # Separator is the markdown horizontal rule.
    assert "\n---\n" in body


def test_export_book_markdown_world_setting_blockquote(client, auth_headers):
    book, _, _ = _seed_book_with_chapters(
        client, auth_headers, world="架空东亚\n民国十年"
    )
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "markdown"},
    )
    assert response.status_code == 200
    body = response.text
    # Each non-empty line of world_setting becomes a ``> line`` blockquote.
    assert "> 架空东亚" in body
    assert "> 民国十年" in body


def test_export_book_markdown_include_drafts_emits_all_chapters(client, auth_headers):
    book, chapter1, chapter2 = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "markdown", "include_drafts": "true"},
    )
    assert response.status_code == 200
    body = response.text
    # Both chapters present; the un-titled second chapter falls back to
    # a bare ``第 N 章`` heading (no `· title` suffix).
    assert f"## 第 {chapter1['index']} 章 · 雨夜山洞" in body
    assert f"## 第 {chapter2['index']} 章" in body
    assert "雨夜山洞" in body
    # The finalized chapter's heading must come before chapter 2 (index
    # ordering, not insertion ordering).
    assert body.index("第 1 章") < body.index("第 2 章")


# ---------------------------------------------------------------------------
# Book export — TXT
# ---------------------------------------------------------------------------


def test_export_book_txt_format_uses_equals_separator(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "txt"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")

    body = response.text
    # Plain text: no `#` markdown markers, just the bare title.
    assert body.startswith(book["title"]), body[:80]
    assert "# " not in body[: len(book["title"]) + 4]
    assert f"第 {chapter1['index']} 章 · 雨夜山洞" in body
    # txt separator is the `========` band (no markdown rule).
    assert "========" in body
    assert "\n---\n" not in body


# ---------------------------------------------------------------------------
# Chapter export
# ---------------------------------------------------------------------------


def test_export_chapter_markdown(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/chapters/{chapter1['id']}/export",
        headers=auth_headers,
        params={"format": "markdown"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")
    body = response.text
    # Book title appears as an H3 caption above the chapter heading.
    assert f"### {book['title']}" in body
    assert f"## 第 {chapter1['index']} 章 · 雨夜山洞" in body
    # The draft text written by MockLLMClient's streamer is included.
    assert "雨声压低了山洞里的呼吸。" in body


def test_export_chapter_txt(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/chapters/{chapter1['id']}/export",
        headers=auth_headers,
        params={"format": "txt"},
    )
    assert response.status_code == 200
    body = response.text
    assert f"《{book['title']}》" in body
    # Chapter heading line (no markdown).
    assert f"第 {chapter1['index']} 章 · 雨夜山洞" in body
    assert "## " not in body


# ---------------------------------------------------------------------------
# Error envelopes
# ---------------------------------------------------------------------------


def test_export_book_not_found_returns_404_with_i18n_message(client, auth_headers):
    response = client.get(
        "/api/v1/books/00000000-0000-0000-0000-000000000000/export",
        headers=auth_headers,
    )
    assert response.status_code == 404
    body = response.json()
    assert body["error"]["kind"] == "not_found"
    # §5.N i18n_not_found("book") template.
    assert body["error"]["message"] == "书籍不存在，可能已被删除"


def test_export_chapter_not_found_returns_404_with_i18n_message(client, auth_headers):
    response = client.get(
        "/api/v1/chapters/00000000-0000-0000-0000-000000000000/export",
        headers=auth_headers,
    )
    assert response.status_code == 404
    body = response.json()
    assert body["error"]["kind"] == "not_found"
    assert body["error"]["message"] == "章节不存在，可能已被删除"


def test_export_book_invalid_format_returns_422(client, auth_headers):
    book, _, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "pdf"},
    )
    assert response.status_code == 422


def test_export_chapter_invalid_format_returns_422(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/chapters/{chapter1['id']}/export",
        headers=auth_headers,
        params={"format": "html"},
    )
    assert response.status_code == 422


def test_export_book_unauthorized_without_bearer(client, auth_headers):
    # Seed a book under the auth'd path (auth_headers mints a real device
    # token), then call export without the Authorization header to confirm
    # the global bearer dependency kicks in.
    book, _, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(f"/api/v1/books/{book['id']}/export")
    assert response.status_code == 401


def test_export_chapter_unauthorized_without_bearer(client, auth_headers):
    book, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(f"/api/v1/chapters/{chapter1['id']}/export")
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Content-Disposition
# ---------------------------------------------------------------------------


def test_export_book_content_disposition_carries_utf8_filename(client, auth_headers):
    book, _, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
        params={"format": "markdown"},
    )
    assert response.status_code == 200
    cd = response.headers["content-disposition"]
    # RFC 5987 form must be present so clients can decode the Chinese
    # filename. The exact percent-encoding depends on `urllib.quote`,
    # so we recompute it for the assertion.
    expected = quote(f"{book['title']}.md", safe="")
    assert f"filename*=UTF-8''{expected}" in cd
    # Plain ASCII fallback also emitted (Chinese chars get `?` replaced).
    assert 'filename="' in cd


def test_export_chapter_content_disposition_uses_chapter_filename(client, auth_headers):
    _, chapter1, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/chapters/{chapter1['id']}/export",
        headers=auth_headers,
        params={"format": "txt"},
    )
    assert response.status_code == 200
    cd = response.headers["content-disposition"]
    expected = quote(f"第{chapter1['index']}章·雨夜山洞.txt", safe="")
    assert f"filename*=UTF-8''{expected}" in cd


def test_export_book_default_format_is_markdown(client, auth_headers):
    """No ``format=`` query → markdown (per Pydantic Literal default)."""
    book, _, _ = _seed_book_with_chapters(client, auth_headers)
    response = client.get(
        f"/api/v1/books/{book['id']}/export",
        headers=auth_headers,
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")
