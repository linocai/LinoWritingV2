from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent

# Style-sample knobs for WriterAgent's "参考前文文风" block.
# Both agent-written and imported finalized chapters feed this — the goal is
# pure stylistic reference, regardless of how the chapter was produced.
STYLE_SAMPLES_CHAPTER_COUNT = 2
STYLE_SAMPLES_CHARS_PER_SIDE = 400


def build_expander_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    return {
        "book": {
            "id": book.id,
            "title": book.title,
            "world_setting": book.world_setting,
            "style_directive": book.style_directive,
        },
        "chapter": {
            "id": chapter.id,
            "index": chapter.index,
            "title": chapter.title,
            "user_prompt": chapter.user_prompt,
        },
        "recent_summaries": _recent_summaries(db, book.id, chapter.index, limit=2),
        "all_characters": [_character_brief(character) for character in _book_characters(db, book.id)],
    }


def build_writer_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    structured_prompt = chapter.structured_prompt or {}
    involved_ids = structured_prompt.get("characters_involved") or []
    characters = _book_characters(db, book.id)
    selected = [character for character in characters if character.id in involved_ids]
    timelines = {character.id: _character_timeline(db, book.id, character.id, limit=15) for character in selected}
    return {
        "world_setting": book.world_setting or "",
        "style_directive": book.style_directive or "",
        "structured_prompt": structured_prompt,
        "characters": [_character_full(character) for character in selected],
        "timelines": timelines,
        "recent_summaries": _recent_summaries(db, book.id, chapter.index, limit=2),
        "style_samples": _style_samples(
            db,
            book.id,
            chapter.index,
            limit=STYLE_SAMPLES_CHAPTER_COUNT,
            chars_per_side=STYLE_SAMPLES_CHARS_PER_SIDE,
        ),
    }


def build_extractor_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    return {
        "chapter": {
            "id": chapter.id,
            "index": chapter.index,
            "title": chapter.title,
            "draft_text": chapter.draft_text,
        },
        "characters": [_character_full(character) for character in _book_characters(db, book.id)],
    }


def _book_characters(db: Session, book_id: str) -> list[Character]:
    return list(db.scalars(select(Character).where(Character.book_id == book_id).order_by(Character.created_at)).all())


def _style_samples(
    db: Session,
    book_id: str,
    before_index: int,
    *,
    limit: int,
    chars_per_side: int,
) -> list[dict[str, Any]]:
    """Latest N finalized chapters' draft_text excerpts for stylistic reference.

    agent-written vs imported chapters are treated identically — we only require
    ``status='finalized'`` and a non-empty ``draft_text``.

    Overlap rule for short chapters: if ``len(draft_text) <= 2 * chars_per_side``
    (head and tail would overlap), we emit the full text as ``head`` and leave
    ``tail`` as an empty string — avoids feeding the same span twice.
    """
    rows = db.scalars(
        select(Chapter)
        .where(
            Chapter.book_id == book_id,
            Chapter.index < before_index,
            Chapter.status == "finalized",
            Chapter.draft_text.is_not(None),
        )
        .order_by(Chapter.index.desc())
        .limit(limit)
    ).all()
    samples: list[dict[str, Any]] = []
    for chapter in reversed(rows):
        text = chapter.draft_text or ""
        if not text:
            continue
        if len(text) <= 2 * chars_per_side:
            # Short chapter — head holds the full draft, tail collapses to ''.
            head = text
            tail = ""
        else:
            head = text[:chars_per_side]
            tail = text[-chars_per_side:]
        samples.append({"chapter_index": chapter.index, "head": head, "tail": tail})
    return samples


def _recent_summaries(db: Session, book_id: str, before_index: int, *, limit: int) -> list[dict[str, Any]]:
    rows = db.scalars(
        select(Chapter)
        .where(Chapter.book_id == book_id, Chapter.index < before_index, Chapter.summary.is_not(None))
        .order_by(Chapter.index.desc())
        .limit(limit)
    ).all()
    return [{"index": chapter.index, "summary": chapter.summary} for chapter in reversed(rows)]


def _character_timeline(db: Session, book_id: str, character_id: str, *, limit: int) -> list[dict[str, Any]]:
    rows = (
        db.execute(
            select(TimelineEvent, Chapter.index.label("chapter_index"))
            .join(Chapter, TimelineEvent.chapter_id == Chapter.id)
            .where(TimelineEvent.book_id == book_id, TimelineEvent.character_id == character_id)
            .order_by(TimelineEvent.created_at.desc())
            .limit(limit)
        )
        .all()
    )
    rows = list(reversed(rows))
    return [
        {
            "chapter_id": event.chapter_id,
            "chapter_index": chapter_index,
            "event_type": event.event_type,
            "event_text": event.event_text,
            "created_at": event.created_at,
        }
        for event, chapter_index in rows
    ]


def _character_brief(character: Character) -> dict[str, Any]:
    frozen = character.frozen_fields or {}
    one_line = frozen.get("core_traits") or frozen.get("background") or frozen.get("voice") or ""
    return {
        "id": character.id,
        "name": character.name,
        "role": character.role,
        "profile": one_line,
    }


def _character_full(character: Character) -> dict[str, Any]:
    return {
        "id": character.id,
        "name": character.name,
        "role": character.role,
        "frozen_fields": character.frozen_fields or {},
        "live_fields": character.live_fields or {},
    }
