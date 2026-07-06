from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import i18n_not_found, i18n_upstream
from app.llm.base import LLMClient, get_extractor_llm_client
from app.llm.errors import LLMError
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.common import utc_now
from app.models.timeline_event import TimelineEvent
from app.schemas.character import (
    CharacterCreate,
    CharacterParseRequest,
    CharacterPatch,
    CharacterRead,
)
from app.schemas.timeline import TimelineEventRead
from app.services.character_parser import land_parsed_characters, parse_characters_from_text

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


@router.post(
    "/books/{book_id}/characters/parse",
    status_code=status.HTTP_201_CREATED,
)
def parse_characters(
    book_id: str,
    payload: CharacterParseRequest,
    db: Session = Depends(get_db),
    # v1.3.0 (II) P2 — reuses the extractor per-Agent key (fallback to
    # generic active key), same as /chapters/{id}/finalize|extract: "把文本
    # 结构化进卡" is the extractor's natural job description.
    llm: LLMClient = Depends(get_extractor_llm_client),
) -> dict[str, list[CharacterRead]]:
    """Parse a pasted character-sheet text blob into landed Character rows.

    PROJECT_PLAN §4 P2 contract: always 201 on a successful LLM round-trip
    (even an empty ``characters: []`` result is not an error — the caller
    only inspects ``items``). LLM transport/shape failures 502 via the
    standard ``i18n_upstream`` envelope. Same-name (trimmed, exact match)
    characters already on the book are skipped, not overwritten.
    """
    _ensure_book(db, book_id)
    try:
        raw_items = parse_characters_from_text(llm, payload.raw_text)
    except (LLMError, ValueError) as exc:
        raise i18n_upstream("llm_generic", retryable=getattr(exc, "retryable", False), detail=str(exc)) from exc

    try:
        created = land_parsed_characters(db, book_id, raw_items)
        db.commit()
    except Exception:
        db.rollback()
        raise
    for character in created:
        db.refresh(character)
    return {"items": [CharacterRead.model_validate(character) for character in created]}


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
    dumped = payload.model_dump(exclude_unset=True)
    for key, value in dumped.items():
        if key not in PATCHABLE_CHARACTER_FIELDS:
            continue
        setattr(character, key, value)
    # v0.7 §5.B (Phase B-fld) — auto-clear field-level highlights for keys
    # the user just edited via ``live_fields`` PATCH. Whole-object replace
    # semantics on live_fields means the user has seen the value for every
    # key they kept; we conservatively clear highlights for the keys present
    # in the NEW live_fields payload (the same set the user just confirmed).
    # frozen_fields / author_notes PATCH do NOT touch highlights — Extractor
    # only writes live_fields, so only those keys can ever be highlighted.
    if "live_fields" in dumped and isinstance(dumped["live_fields"], dict):
        existing_highlights = dict(character.pending_field_highlights or {})
        if existing_highlights:
            for key in dumped["live_fields"].keys():
                existing_highlights.pop(key, None)
            character.pending_field_highlights = existing_highlights
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
        raise i18n_not_found("book")


def _get_character(db: Session, character_id: str) -> Character:
    character = db.get(Character, character_id)
    if character is None:
        raise i18n_not_found("character")
    return character
