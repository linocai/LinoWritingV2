from __future__ import annotations

from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.errors import i18n_upstream
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent
from app.models.common import utc_now
from app.services.chapter_state import TIMELINE_EVENT_TYPES


def apply_extractor_output(db: Session, chapter: Chapter, output: dict[str, Any]) -> tuple[list[str], list[str]]:
    summary = output.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise i18n_upstream("extractor_missing_summary", retryable=True)

    timeline_events = output.get("timeline_events") or []
    character_updates = output.get("character_updates") or []
    if not isinstance(timeline_events, list):
        raise i18n_upstream("extractor_bad_timeline_events", retryable=True)
    if not isinstance(character_updates, list):
        raise i18n_upstream("extractor_bad_character_updates", retryable=True)

    character_map = {
        character.id: character
        for character in db.scalars(select(Character).where(Character.book_id == chapter.book_id)).all()
    }

    updated_character_ids: list[str] = []
    for item in character_updates:
        if not isinstance(item, dict):
            raise i18n_upstream("extractor_character_update_not_object", retryable=True)
        character_id = item.get("character_id")
        patch = item.get("live_fields_patch") or {}
        if character_id not in character_map:
            raise i18n_upstream(
                "extractor_unknown_character",
                retryable=True,
                details={"character_id": character_id},
            )
        if not isinstance(patch, dict):
            raise i18n_upstream("extractor_character_patch_not_object", retryable=True)
        character = character_map[character_id]
        merged = dict(character.live_fields or {})
        merged.update(patch)
        character.live_fields = merged
        # v0.7 §5.B (Phase B-fld) — field-level dot indicator.
        # ``patch_keys`` is what the LLM declared; ``patch.keys()`` is the
        # actual mutation. We trust ``patch.keys()`` as the source of truth
        # (the LLM can lie) and ignore patch_keys for now — but the schema
        # slot is kept so future LLMs can self-describe and we can extend
        # to "highlight nested key paths" without contract change.
        now_iso = utc_now().isoformat()
        existing_highlights = dict(character.pending_field_highlights or {})
        for key in patch.keys():
            existing_highlights[key] = now_iso
        character.pending_field_highlights = existing_highlights
        character.updated_at = utc_now()
        updated_character_ids.append(character.id)

    db.execute(delete(TimelineEvent).where(TimelineEvent.chapter_id == chapter.id))

    added_event_ids: list[str] = []
    for item in timeline_events:
        if not isinstance(item, dict):
            raise i18n_upstream("extractor_event_not_object", retryable=True)
        character_id = item.get("character_id")
        event_type = item.get("event_type")
        event_text = item.get("event_text")
        if character_id not in character_map:
            raise i18n_upstream(
                "extractor_unknown_character",
                retryable=True,
                details={"character_id": character_id},
            )
        if event_type not in TIMELINE_EVENT_TYPES:
            raise i18n_upstream(
                "extractor_bad_event_type",
                retryable=True,
                details={"event_type": event_type},
            )
        if not isinstance(event_text, str) or not event_text.strip():
            raise i18n_upstream("extractor_empty_event_text", retryable=True)
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
