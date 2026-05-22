from __future__ import annotations

from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.errors import upstream
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent
from app.models.common import utc_now
from app.services.chapter_state import TIMELINE_EVENT_TYPES


def apply_extractor_output(db: Session, chapter: Chapter, output: dict[str, Any]) -> tuple[list[str], list[str]]:
    summary = output.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise upstream("Extractor output missing summary", retryable=True)

    timeline_events = output.get("timeline_events") or []
    character_updates = output.get("character_updates") or []
    if not isinstance(timeline_events, list):
        raise upstream("Extractor timeline_events must be a list", retryable=True)
    if not isinstance(character_updates, list):
        raise upstream("Extractor character_updates must be a list", retryable=True)

    character_map = {
        character.id: character
        for character in db.scalars(select(Character).where(Character.book_id == chapter.book_id)).all()
    }

    updated_character_ids: list[str] = []
    for item in character_updates:
        if not isinstance(item, dict):
            raise upstream("Extractor character update must be an object", retryable=True)
        character_id = item.get("character_id")
        patch = item.get("live_fields_patch") or {}
        if character_id not in character_map:
            raise upstream(
                "Extractor referenced an unknown character",
                retryable=True,
                details={"character_id": character_id},
            )
        if not isinstance(patch, dict):
            raise upstream("Extractor character update patch must be an object", retryable=True)
        character = character_map[character_id]
        merged = dict(character.live_fields or {})
        merged.update(patch)
        character.live_fields = merged
        character.updated_at = utc_now()
        updated_character_ids.append(character.id)

    db.execute(delete(TimelineEvent).where(TimelineEvent.chapter_id == chapter.id))

    added_event_ids: list[str] = []
    for item in timeline_events:
        if not isinstance(item, dict):
            raise upstream("Extractor timeline event must be an object", retryable=True)
        character_id = item.get("character_id")
        event_type = item.get("event_type")
        event_text = item.get("event_text")
        if character_id not in character_map:
            raise upstream(
                "Extractor referenced an unknown character",
                retryable=True,
                details={"character_id": character_id},
            )
        if event_type not in TIMELINE_EVENT_TYPES:
            raise upstream(
                "Extractor emitted an invalid event_type",
                retryable=True,
                details={"event_type": event_type},
            )
        if not isinstance(event_text, str) or not event_text.strip():
            raise upstream("Extractor emitted an empty event_text", retryable=True)
        event = TimelineEvent(
            book_id=chapter.book_id,
            character_id=character_id,
            chapter_id=chapter.id,
            event_type=event_type,
            event_text=event_text.strip()[:120],
        )
        db.add(event)
        db.flush()
        added_event_ids.append(event.id)

    chapter.summary = summary.strip()
    chapter.status = "finalized"
    chapter.updated_at = utc_now()
    return sorted(set(updated_character_ids)), added_event_ids
