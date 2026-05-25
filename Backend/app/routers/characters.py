from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import not_found
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.common import utc_now
from app.models.timeline_event import TimelineEvent
from app.schemas.character import CharacterCreate, CharacterPatch, CharacterRead
from app.schemas.timeline import TimelineEventRead

router = APIRouter(tags=["characters"])


@router.get("/books/{book_id}/characters")
def list_characters(book_id: str, db: Session = Depends(get_db)) -> dict[str, list[CharacterRead]]:
    _ensure_book(db, book_id)
    characters = db.scalars(select(Character).where(Character.book_id == book_id).order_by(Character.created_at)).all()
    return {"items": [CharacterRead.model_validate(character) for character in characters]}


@router.post("/books/{book_id}/characters", response_model=CharacterRead, status_code=status.HTTP_201_CREATED)
def create_character(book_id: str, payload: CharacterCreate, db: Session = Depends(get_db)) -> CharacterRead:
    _ensure_book(db, book_id)
    character = Character(
        book_id=book_id,
        name=payload.name,
        role=payload.role,
        frozen_fields=payload.frozen_fields,
        live_fields=payload.live_fields,
        author_notes=payload.author_notes,
    )
    db.add(character)
    db.commit()
    db.refresh(character)
    return CharacterRead.model_validate(character)


@router.get("/characters/{character_id}", response_model=CharacterRead)
def get_character(character_id: str, db: Session = Depends(get_db)) -> CharacterRead:
    return CharacterRead.model_validate(_get_character(db, character_id))


# Second-layer allowlist mirroring the chapters router pattern from
# §5.P.1 F. The Pydantic CharacterPatch schema is *already* a whitelist
# (it only exposes these 5 fields), but a router-side allowlist guards
# against a future maintainer carelessly adding read-only fields (e.g.
# book_id, id) to CharacterPatch and accidentally opening a
# mass-assignment vector. L-1 reviewer 🟡 #2.
PATCHABLE_CHARACTER_FIELDS = frozenset(
    {"name", "role", "frozen_fields", "live_fields", "author_notes"}
)


@router.patch("/characters/{character_id}", response_model=CharacterRead)
def patch_character(character_id: str, payload: CharacterPatch, db: Session = Depends(get_db)) -> CharacterRead:
    character = _get_character(db, character_id)
    for key, value in payload.model_dump(exclude_unset=True).items():
        if key not in PATCHABLE_CHARACTER_FIELDS:
            continue
        setattr(character, key, value)
    character.updated_at = utc_now()
    db.commit()
    db.refresh(character)
    return CharacterRead.model_validate(character)


@router.delete("/characters/{character_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character(character_id: str, db: Session = Depends(get_db)) -> Response:
    character = _get_character(db, character_id)
    db.delete(character)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/characters/{character_id}/timeline")
def character_timeline(
    character_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    before: datetime | None = None,
    db: Session = Depends(get_db),
) -> dict[str, list[TimelineEventRead]]:
    character = _get_character(db, character_id)
    query = (
        select(TimelineEvent, Chapter.index.label("chapter_index"))
        .join(Chapter, TimelineEvent.chapter_id == Chapter.id)
        .where(TimelineEvent.book_id == character.book_id, TimelineEvent.character_id == character.id)
        .order_by(TimelineEvent.created_at.desc())
        .limit(limit)
    )
    if before is not None:
        query = query.where(TimelineEvent.created_at < before)
    rows = db.execute(query).all()
    return {
        "items": [
            TimelineEventRead.model_validate(
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
            for event, chapter_index in rows
        ]
    }


def _ensure_book(db: Session, book_id: str) -> None:
    if db.get(Book, book_id) is None:
        raise not_found("Book not found")


def _get_character(db: Session, character_id: str) -> Character:
    character = db.get(Character, character_id)
    if character is None:
        raise not_found("Character not found")
    return character
