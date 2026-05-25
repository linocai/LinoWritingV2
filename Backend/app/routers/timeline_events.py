from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import i18n_not_found
from app.models.chapter import Chapter
from app.models.common import utc_now
from app.models.timeline_event import TimelineEvent
from app.schemas.timeline import TimelineEventPatch, TimelineEventRead

router = APIRouter(tags=["timeline_events"])

# Router-level allowlist mirroring the chapters / characters PATCH pattern
# (§5.P.1 F). ``TimelineEventPatch`` already only exposes these two fields,
# but a second guard here makes any future schema regression (e.g. someone
# adding ``character_id`` to the patch schema by accident) a no-op at the
# router instead of a silent cross-chapter / cross-character mass-assignment.
PATCHABLE_TIMELINE_EVENT_FIELDS = frozenset({"event_text", "event_type"})


@router.patch("/timeline_events/{event_id}", response_model=TimelineEventRead)
def patch_timeline_event(
    event_id: str,
    payload: TimelineEventPatch,
    db: Session = Depends(get_db),
) -> TimelineEventRead:
    """Edit ``event_text`` and/or ``event_type`` on an existing event.

    Stamps ``edited_at = utc_now()`` on every successful PATCH so the frontend
    can render a "已编辑" marker distinguishing user-touched rows from rows
    the Extractor wrote and never anyone touched.

    422 if the body carries neither ``event_text`` nor ``event_type`` (enforced
    by ``TimelineEventPatch.require_at_least_one_field``). 404 if the event id
    does not exist.
    """
    event = _get_event(db, event_id)
    incoming = payload.model_dump(exclude_unset=True)
    # C-tl reviewer 🔵 #4: only stamp edited_at when a field actually
    # changes. Without this guard, a blur-triggered save that re-sends
    # the unchanged value (e.g. user double-clicked, didn't edit, then
    # clicked away) would light up the "已编辑" badge even though the
    # content is identical. Frontend has a similar guard, but defence
    # in depth keeps the audit signal honest.
    dirty = False
    for key, value in incoming.items():
        if key not in PATCHABLE_TIMELINE_EVENT_FIELDS:
            continue
        if getattr(event, key) != value:
            setattr(event, key, value)
            dirty = True
    if dirty:
        event.edited_at = utc_now()
    db.commit()
    db.refresh(event)
    # The Read schema needs ``chapter_index`` — read it from the joined Chapter
    # (timeline rows always belong to exactly one Chapter; ``chapter_id`` is NOT
    # NULL). One extra GET-by-PK is fine, this endpoint is not on a hot path.
    chapter = db.get(Chapter, event.chapter_id)
    chapter_index = chapter.index if chapter is not None else 0
    return TimelineEventRead.model_validate(
        {
            "id": event.id,
            "book_id": event.book_id,
            "character_id": event.character_id,
            "chapter_id": event.chapter_id,
            "chapter_index": chapter_index,
            "event_type": event.event_type,
            "event_text": event.event_text,
            "created_at": event.created_at,
            "edited_at": event.edited_at,
        }
    )


@router.delete("/timeline_events/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_timeline_event(
    event_id: str,
    db: Session = Depends(get_db),
) -> Response:
    """Physically delete a single timeline event. No soft-delete (§5.C.2)."""
    event = _get_event(db, event_id)
    db.delete(event)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _get_event(db: Session, event_id: str) -> TimelineEvent:
    event = db.get(TimelineEvent, event_id)
    if event is None:
        raise i18n_not_found("timeline_event")
    return event
