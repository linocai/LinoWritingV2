from __future__ import annotations

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.services.context_pack import (
    RECENT_FULLTEXT_COUNT,
    RECENT_SUMMARY_COUNT,
    STYLE_SAMPLES_CHAPTER_COUNT,
    STYLE_SAMPLES_CHARS_PER_SIDE,
    _recent_finalized,
    build_writer_context,
)


def _seed_minimal_book(db_session) -> tuple[Book, Character]:
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id,
        name="林夕",
        role="主角",
        frozen_fields={"core_traits": "谨慎"},
        live_fields={},
    )
    db_session.add(character)
    db_session.flush()
    return book, character


def _long_text(prefix: str, char_count: int) -> str:
    # Concatenate a Chinese char to reach desired length predictably.
    unit = "字"
    body = unit * char_count
    return f"{prefix}{body}"


# --------------------------------------------------------------------------
# v1.3.1 (KK) P7 — at the ``build_writer_context`` level, style_samples has NO
# non-empty reachable path in production (審後修復 🔵1, reviewer 抓出):
# ``fulltext_rows``/``style_rows`` inside ``_recent_finalized`` share the same
# source rows and the same non-empty-draft_text filter, so style_samples can
# only be non-empty when recent_fulltext is ALSO non-empty — and whenever
# that happens, ``build_writer_context`` unconditionally zeroes style_samples
# right back out (the same chapters would otherwise be double-fed — once as
# recent_fulltext, once as head/tail snippets). This holds even at a single
# finalized chapter (well under RECENT_FULLTEXT_COUNT=3) — there is no
# chapter count at which the zero-out is skipped. The mechanics of head/tail
# slicing themselves are tested directly against ``_recent_finalized`` with
# ``fulltext_limit=0`` (bypassing build_writer_context's zero-out) so the
# underlying slicing behaviour stays locked even though it's currently
# unreachable end-to-end; the zero-out itself is tested at the
# build_writer_context level below.
# --------------------------------------------------------------------------


def test_style_samples_mechanism_returns_latest_n_finalized_chapters(db_session):
    """Directly exercises `_recent_finalized`'s style_samples slicing, with
    fulltext_limit=0 so the fulltext window can't interfere."""
    book, character = _seed_minimal_book(db_session)
    # 4 finalized chapters.
    for i in range(1, 5):
        db_session.add(
            Chapter(
                book_id=book.id,
                index=i,
                user_prompt=f"第{i}章",
                draft_text=_long_text(f"第{i}章 — ", 1000),
                summary=f"第{i}章摘要",
                status="finalized",
                source="agent",
            )
        )
    db_session.commit()

    _, _, _, samples = _recent_finalized(
        db_session,
        book.id,
        5,
        fulltext_limit=0,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        summary_limit=RECENT_SUMMARY_COUNT,
    )
    assert len(samples) == STYLE_SAMPLES_CHAPTER_COUNT == 2
    # Latest two: chapters 3 and 4, returned in ascending order (oldest first).
    assert [s["chapter_index"] for s in samples] == [3, 4]
    for sample in samples:
        assert len(sample["head"]) == STYLE_SAMPLES_CHARS_PER_SIDE
        assert len(sample["tail"]) == STYLE_SAMPLES_CHARS_PER_SIDE


def test_style_samples_mechanism_treats_imported_and_agent_chapters_alike(db_session):
    book, character = _seed_minimal_book(db_session)
    # ch1 agent, ch2 imported — both finalized.
    db_session.add(
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text=_long_text("agent写的 — ", 1000),
            summary="一",
            status="finalized",
            source="agent",
        )
    )
    db_session.add(
        Chapter(
            book_id=book.id,
            index=2,
            user_prompt="二",
            draft_text=_long_text("用户导入 — ", 1000),
            summary="二",
            status="finalized",
            source="imported",
        )
    )
    db_session.commit()

    _, _, _, samples = _recent_finalized(
        db_session,
        book.id,
        3,
        fulltext_limit=0,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        summary_limit=RECENT_SUMMARY_COUNT,
    )
    assert [s["chapter_index"] for s in samples] == [1, 2]
    # Imported chapter's text is present in samples — proves source filter is absent.
    assert "用户导入" in samples[1]["head"]
    assert "agent写的" in samples[0]["head"]


def test_style_samples_mechanism_short_chapter_head_holds_full_tail_empty(db_session):
    """If draft_text length <= 2 * chars_per_side, head holds the full text, tail is ''."""
    book, character = _seed_minimal_book(db_session)
    short_text = "短章节" * 50  # 150 chars — well under 2*400.
    db_session.add(
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text=short_text,
            summary="一",
            status="finalized",
            source="agent",
        )
    )
    db_session.commit()

    _, _, _, samples = _recent_finalized(
        db_session,
        book.id,
        2,
        fulltext_limit=0,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        summary_limit=RECENT_SUMMARY_COUNT,
    )
    assert len(samples) == 1
    assert samples[0]["head"] == short_text
    assert samples[0]["tail"] == ""


def test_style_samples_mechanism_returns_fewer_than_n_when_not_enough(db_session):
    book, character = _seed_minimal_book(db_session)
    db_session.add(
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text=_long_text("内容 — ", 1000),
            summary="一",
            status="finalized",
            source="agent",
        )
    )
    db_session.commit()

    _, _, _, samples = _recent_finalized(
        db_session,
        book.id,
        2,
        fulltext_limit=0,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        summary_limit=RECENT_SUMMARY_COUNT,
    )
    assert len(samples) == 1


def test_style_samples_empty_when_no_finalized_chapters(db_session):
    book, character = _seed_minimal_book(db_session)
    # Only non-finalized chapters exist.
    db_session.add(
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text="未定稿正文。",
            status="draft_ready",
            source="agent",
        )
    )
    current = Chapter(
        book_id=book.id,
        index=2,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert ctx["style_samples"] == []


# --------------------------------------------------------------------------
# build_writer_context-level: style_samples is zeroed whenever the fulltext
# window hits at all (recent_fulltext non-empty) — the P7 anti-duplication
# rule. Since style_rows/fulltext_rows share the same source + filter, the
# ONLY case where fulltext is empty is when there are ZERO finalized
# chapters — and at zero chapters there is nothing to sample either, so
# style_samples never actually gets a non-empty fallback value in practice
# (see the module-level comment atop this file for the full reasoning).
# --------------------------------------------------------------------------


def test_build_writer_context_zeroes_style_samples_when_fulltext_window_hits(db_session):
    book, character = _seed_minimal_book(db_session)
    # A single finalized chapter is enough to populate recent_fulltext (window
    # size RECENT_FULLTEXT_COUNT=3 — 1 <= 3, so it lands in recent_fulltext).
    db_session.add(
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text=_long_text("正文 — ", 1000),
            summary="一",
            status="finalized",
            source="agent",
        )
    )
    current = Chapter(
        book_id=book.id,
        index=2,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert len(ctx["recent_fulltext"]) == 1
    assert ctx["style_samples"] == []


def test_build_writer_context_style_samples_fallback_when_no_finalized_chapters_yet(db_session):
    """The very first chapter of a book: no finalized chapters exist at all,
    so recent_fulltext is empty and style_samples correctly stays empty too
    (there's nothing to sample from either way)."""
    book, character = _seed_minimal_book(db_session)
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert ctx["recent_fulltext"] == []
    assert ctx["style_samples"] == []


def test_recent_fulltext_bounded_at_recent_fulltext_count_regardless_of_total_chapters(db_session):
    """Locks the P7 invariant: recent_fulltext never exceeds
    RECENT_FULLTEXT_COUNT, even with many more finalized chapters available."""
    book, character = _seed_minimal_book(db_session)
    for i in range(1, 8):  # 7 finalized chapters — well over RECENT_FULLTEXT_COUNT=3.
        db_session.add(
            Chapter(
                book_id=book.id,
                index=i,
                user_prompt=f"第{i}章",
                draft_text=_long_text(f"第{i}章 — ", 500),
                summary=f"第{i}章摘要",
                status="finalized",
                source="agent",
            )
        )
    current = Chapter(
        book_id=book.id,
        index=8,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert len(ctx["recent_fulltext"]) == RECENT_FULLTEXT_COUNT == 3
    assert [c["index"] for c in ctx["recent_fulltext"]] == [5, 6, 7]
    # Older chapters (1-4) show up as summary-only — well under
    # RECENT_SUMMARY_COUNT=30, so nothing spills into recent_headlines yet
    # (v1.3.2 LL P3 third tier).
    assert [s["index"] for s in ctx["recent_summaries"]] == [1, 2, 3, 4]
    assert ctx["recent_headlines"] == []
