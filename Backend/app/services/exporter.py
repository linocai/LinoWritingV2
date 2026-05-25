"""Markdown / TXT exporters for chapters and whole books.

v0.7 §5.F — pure string-concat layer with **no DB access**. Callers (the
``books``/``chapters`` routers) are responsible for fetching the
``Book`` and the relevant ``Chapter`` rows in the desired order, then
handing them to one of the four ``export_*`` functions in this module.

Two formats are exposed:

* ``markdown`` — H1 book title, optional H2 world setting blockquote,
  per-chapter H2 with ``第 N 章 · {title}`` heading. Chapters separated
  by ``---`` horizontal rule.
* ``txt`` — plain text. Chapter heading reduced to ``第 N 章 · {title}``
  on its own line, body follows. Chapters separated by a long ``=`` rule
  surrounded by blank lines.

Two small filename helpers (`build_filename`, `build_content_disposition`)
live here too so both routers can share the same RFC 5987 encoding —
otherwise the chapter and book routers would each grow their own copy.
"""

from __future__ import annotations

from collections.abc import Iterable
from urllib.parse import quote

from app.models.book import Book
from app.models.chapter import Chapter


# Section separator used in both formats. Markdown uses the ATX rule;
# plain text uses an `=` band wide enough to read at a glance but short
# enough to fit any terminal.
_MD_SECTION_RULE = "\n\n---\n\n"
_TXT_SECTION_RULE = "\n\n========\n\n"


def _filter_chapters(
    chapters: Iterable[Chapter],
    *,
    include_drafts: bool,
) -> list[Chapter]:
    """Filter + sort chapters for export.

    ``include_drafts=False`` (the default at the router) means only
    chapters in ``finalized`` state are exported. ``include_drafts=True``
    exports everything regardless of status. Sorting is always by
    ``index`` ascending so the resulting file matches the book's reading
    order — even if the caller hands us an out-of-order list.
    """
    selected = [
        ch for ch in chapters if include_drafts or ch.status == "finalized"
    ]
    selected.sort(key=lambda ch: ch.index)
    return selected


def _chapter_heading(chapter: Chapter) -> str:
    """``第 N 章 · 标题`` (or just ``第 N 章`` if no title)."""
    title = (chapter.title or "").strip()
    if title:
        return f"第 {chapter.index} 章 · {title}"
    return f"第 {chapter.index} 章"


# ---------------------------------------------------------------------------
# Book exporters
# ---------------------------------------------------------------------------


def export_book_markdown(
    book: Book,
    chapters: Iterable[Chapter],
    *,
    include_drafts: bool = False,
) -> str:
    """Return a Markdown rendering of ``book`` + its chapters.

    See module docstring for the layout. World setting blockquote is
    skipped entirely when ``book.world_setting`` is empty/None.
    """
    lines: list[str] = [f"# {book.title}"]

    world = (book.world_setting or "").strip()
    if world:
        # Quote every line of the world setting so multi-paragraph
        # settings still render as a single blockquote in markdown.
        quoted = "\n".join(f"> {line}" if line else ">" for line in world.split("\n"))
        lines.append("")
        lines.append(quoted)

    body_sections: list[str] = []
    for chapter in _filter_chapters(chapters, include_drafts=include_drafts):
        heading = _chapter_heading(chapter)
        draft = (chapter.draft_text or "").strip()
        if draft:
            body_sections.append(f"## {heading}\n\n{draft}")
        else:
            body_sections.append(f"## {heading}")

    head = "\n".join(lines)
    if not body_sections:
        return head + "\n"

    return head + _MD_SECTION_RULE + _MD_SECTION_RULE.join(body_sections) + "\n"


def export_book_txt(
    book: Book,
    chapters: Iterable[Chapter],
    *,
    include_drafts: bool = False,
) -> str:
    """Return a plain-text rendering of ``book`` + its chapters.

    Plain text omits the world-setting blockquote markup; if the book
    has a world setting we still include it (one blank line after the
    title), but without any ``>`` prefix.
    """
    parts: list[str] = [book.title]

    world = (book.world_setting or "").strip()
    if world:
        parts.append("")
        parts.append(world)

    head = "\n".join(parts)

    body_sections: list[str] = []
    for chapter in _filter_chapters(chapters, include_drafts=include_drafts):
        heading = _chapter_heading(chapter)
        draft = (chapter.draft_text or "").strip()
        if draft:
            body_sections.append(f"{heading}\n\n{draft}")
        else:
            body_sections.append(heading)

    if not body_sections:
        return head + "\n"

    return head + _TXT_SECTION_RULE + _TXT_SECTION_RULE.join(body_sections) + "\n"


# ---------------------------------------------------------------------------
# Single-chapter exporters
# ---------------------------------------------------------------------------


def export_chapter_markdown(chapter: Chapter, book: Book) -> str:
    """Single-chapter markdown export.

    Carries the book title as a tiny H3 caption above the chapter heading
    so the file is self-describing if the user shares it standalone. No
    status / drafts filter — when the user explicitly exports one chapter
    they always want it regardless of state.
    """
    heading = _chapter_heading(chapter)
    draft = (chapter.draft_text or "").strip()
    lines = [f"### {book.title}", "", f"## {heading}"]
    if draft:
        lines.append("")
        lines.append(draft)
    return "\n".join(lines) + "\n"


def export_chapter_txt(chapter: Chapter, book: Book) -> str:
    """Single-chapter plain-text export.

    First line is ``《书名》`` as a soft caption (mirrors the markdown
    ``###``), then a blank line, then the chapter heading and body.
    """
    heading = _chapter_heading(chapter)
    draft = (chapter.draft_text or "").strip()
    lines = [f"《{book.title}》", "", heading]
    if draft:
        lines.append("")
        lines.append(draft)
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Filename / Content-Disposition helpers (shared by both routers)
# ---------------------------------------------------------------------------


def build_filename(base: str | None, extension: str) -> str:
    """Build a safe download filename from a free-form title + extension.

    Falls back to ``untitled`` when ``base`` is blank, and strips path-
    separator-ish characters so a permissive client can't be tricked
    into traversing directories on the receiving filesystem. Non-ASCII
    characters (Chinese, emoji) are preserved as-is — the caller
    URL-encodes them in the Content-Disposition header.
    """
    safe = (base or "").strip()
    if not safe:
        safe = "untitled"
    for ch in ("/", "\\", "\x00", "\r", "\n"):
        safe = safe.replace(ch, "_")
    return f"{safe}.{extension}"


def build_content_disposition(filename: str) -> str:
    """RFC 5987 ``Content-Disposition: attachment`` header value.

    Emits BOTH a plain ``filename="..."`` (ASCII-only fallback) and a
    ``filename*=UTF-8''...`` (URL-encoded UTF-8). Browsers / macOS
    Foundation pick the encoded form when it parses, so Chinese
    chapter titles survive the trip. The ASCII fallback is just in
    case a primitive client only reads the plain ``filename``.
    """
    ascii_fallback = filename.encode("ascii", errors="replace").decode("ascii")
    encoded = quote(filename, safe="")
    return (
        f"attachment; filename=\"{ascii_fallback}\"; "
        f"filename*=UTF-8''{encoded}"
    )
