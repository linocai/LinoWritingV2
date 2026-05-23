from __future__ import annotations

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.services.context_pack import (
    STYLE_SAMPLES_CHAPTER_COUNT,
    STYLE_SAMPLES_CHARS_PER_SIDE,
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


def test_style_samples_returns_latest_n_finalized_chapters(db_session):
    book, character = _seed_minimal_book(db_session)
    # 4 finalized chapters + 1 current (draft).
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
    current = Chapter(
        book_id=book.id,
        index=5,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    samples = ctx["style_samples"]
    assert len(samples) == STYLE_SAMPLES_CHAPTER_COUNT == 2
    # Latest two: chapters 3 and 4, returned in ascending order (oldest first).
    assert [s["chapter_index"] for s in samples] == [3, 4]
    for sample in samples:
        assert len(sample["head"]) == STYLE_SAMPLES_CHARS_PER_SIDE
        assert len(sample["tail"]) == STYLE_SAMPLES_CHARS_PER_SIDE


def test_style_samples_treats_imported_and_agent_chapters_alike(db_session):
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
    current = Chapter(
        book_id=book.id,
        index=3,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    samples = ctx["style_samples"]
    assert [s["chapter_index"] for s in samples] == [1, 2]
    # Imported chapter's text is present in samples — proves source filter is absent.
    assert "用户导入" in samples[1]["head"]
    assert "agent写的" in samples[0]["head"]


def test_style_samples_short_chapter_head_holds_full_tail_empty(db_session):
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
    samples = ctx["style_samples"]
    assert len(samples) == 1
    assert samples[0]["head"] == short_text
    assert samples[0]["tail"] == ""


def test_style_samples_returns_fewer_than_n_when_not_enough(db_session):
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
    samples = ctx["style_samples"]
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
