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
    build_expander_context,
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
        structured_prompt={"characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert "style_samples" not in ctx
    assert ctx["previous_chapter_summary"] is None
    assert ctx["recent_summaries"] == []


# --------------------------------------------------------------------------
# build_writer_context-level: v1.3.4 快修 — Writer 彻底断原文. The Writer no
# longer receives ``recent_fulltext`` OR ``style_samples`` at all — neither
# key is ever present in ``build_writer_context``'s return dict, regardless
# of how many finalized chapters exist. What used to be the fulltext window
# now always lands in the summary tier instead (split into
# ``previous_chapter_summary`` + ``recent_summaries``). The
# ``RECENT_FULLTEXT_COUNT``-bounded-window invariant itself is untouched —
# it just now only applies to the Expander (see
# ``test_recent_fulltext_bounded_at_recent_fulltext_count_regardless_of_total_chapters``
# below, ported to ``build_expander_context``).
# --------------------------------------------------------------------------


def test_build_writer_context_never_carries_fulltext_even_with_one_finalized_chapter(db_session):
    book, character = _seed_minimal_book(db_session)
    # A single finalized chapter — well within the old RECENT_FULLTEXT_COUNT=3
    # window — used to land in recent_fulltext; now it's summary-only.
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
        structured_prompt={"characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert "recent_fulltext" not in ctx
    assert "style_samples" not in ctx
    assert ctx["previous_chapter_summary"]["index"] == 1
    assert ctx["previous_chapter_summary"]["summary"] == "一"
    assert ctx["recent_summaries"] == []


def test_build_writer_context_no_fulltext_fallback_when_no_finalized_chapters_yet(db_session):
    """The very first chapter of a book: no finalized chapters exist at all,
    so both the summary tiers and the (absent) fulltext/style keys are empty."""
    book, character = _seed_minimal_book(db_session)
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert "recent_fulltext" not in ctx
    assert "style_samples" not in ctx
    assert ctx["previous_chapter_summary"] is None
    assert ctx["recent_summaries"] == []


def test_recent_fulltext_bounded_at_recent_fulltext_count_regardless_of_total_chapters(db_session):
    """Locks the P7 invariant: recent_fulltext never exceeds
    RECENT_FULLTEXT_COUNT, even with many more finalized chapters available.

    v1.3.4 快修: this invariant now only applies to the Expander (the Writer
    no longer has a recent_fulltext channel at all — see the tests above), so
    this test targets ``build_expander_context`` instead of
    ``build_writer_context``. The underlying mechanism/constant is otherwise
    unchanged.
    """
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
        structured_prompt={"characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_expander_context(db_session, book, current)
    assert len(ctx["recent_fulltext"]) == RECENT_FULLTEXT_COUNT == 3
    assert [c["index"] for c in ctx["recent_fulltext"]] == [5, 6, 7]
    # Older chapters (1-4) show up as summary-only — well under
    # RECENT_SUMMARY_COUNT=30, so nothing spills into recent_headlines yet
    # (v1.3.2 LL P3 third tier).
    assert [s["index"] for s in ctx["recent_summaries"]] == [1, 2, 3, 4]
    assert ctx["recent_headlines"] == []
