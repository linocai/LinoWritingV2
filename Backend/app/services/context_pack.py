from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent


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
