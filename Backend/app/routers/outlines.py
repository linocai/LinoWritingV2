from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import i18n_not_found
from app.models.book import Book
from app.models.book_outline import BookOutline
from app.models.common import utc_now
from app.schemas.outline import BookOutlineRead, OutlineIngest, OutlinePatch

# v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §5.1) — book outline ingest /
# read / patch. The outline is a singleton per book (``book_id`` UNIQUE):
# ingest upserts, never runs an LLM, and always succeeds (mirrors the
# chapter-import philosophy). There is NO digest endpoint — the outline is
# plain prose, not structurally parsed.
router = APIRouter(tags=["outlines"])


@router.post("/books/{book_id}/outline/ingest")
def ingest_outline(
    book_id: str,
    payload: OutlineIngest,
    db: Session = Depends(get_db),
) -> dict[str, BookOutlineRead]:
    """Upsert the book's outline ``raw_text``. No LLM, always succeeds."""
    _get_book(db, book_id)
    outline = _get_outline(db, book_id)
    if outline is None:
        outline = BookOutline(book_id=book_id, raw_text=payload.raw_text)
        db.add(outline)
    else:
        outline.raw_text = payload.raw_text
        outline.updated_at = utc_now()
    db.commit()
    db.refresh(outline)
    return {"outline": BookOutlineRead.model_validate(outline)}


@router.get("/books/{book_id}/outline")
def get_outline(book_id: str, db: Session = Depends(get_db)) -> dict[str, BookOutlineRead | None]:
    """Return the book's outline, or ``{"outline": null}`` when none exists."""
    _get_book(db, book_id)
    outline = _get_outline(db, book_id)
    if outline is None:
        return {"outline": None}
    return {"outline": BookOutlineRead.model_validate(outline)}


@router.patch("/books/{book_id}/outline")
def patch_outline(
    book_id: str,
    payload: OutlinePatch,
    db: Session = Depends(get_db),
) -> dict[str, BookOutlineRead]:
    """Author hand-edit of the living outline. Whitelist: ``raw_text`` only.

    PATCH on a book that never ingested an outline upserts one (so the author
    can author the outline straight from the edit surface).
    """
    _get_book(db, book_id)
    outline = _get_outline(db, book_id)
    if outline is None:
        outline = BookOutline(book_id=book_id)
        db.add(outline)
    # exclude_unset → an absent key is a no-op, not a null overwrite. The
    # whitelist is enforced by the OutlinePatch schema (raw_text only).
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(outline, key, value)
    outline.updated_at = utc_now()
    db.commit()
    db.refresh(outline)
    return {"outline": BookOutlineRead.model_validate(outline)}


def _get_book(db: Session, book_id: str) -> Book:
    book = db.get(Book, book_id)
    if book is None:
        raise i18n_not_found("book")
    return book


def _get_outline(db: Session, book_id: str) -> BookOutline | None:
    return db.scalar(select(BookOutline).where(BookOutline.book_id == book_id))
