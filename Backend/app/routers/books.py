from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import i18n_not_found
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.common import utc_now
from app.schemas.book import BookCreate, BookPatch, BookRead
from app.services.exporter import (
    build_content_disposition,
    build_filename,
    export_book_markdown,
    export_book_txt,
)

router = APIRouter(tags=["books"])

# v0.7 §5.F — supported export formats. Pydantic-style ``Literal`` so
# FastAPI auto-rejects anything else as 422 before the handler is even
# called.
ExportFormat = Literal["markdown", "txt"]


@router.get("/books")
def list_books(db: Session = Depends(get_db)) -> dict[str, list[BookRead]]:
    books = db.scalars(select(Book).order_by(Book.last_opened_at.desc(), Book.updated_at.desc())).all()
    return {"items": [_book_read(db, book) for book in books]}


@router.post("/books", response_model=BookRead, status_code=status.HTTP_201_CREATED)
def create_book(payload: BookCreate, db: Session = Depends(get_db)) -> BookRead:
    book = Book(title=payload.title, cover_color=payload.cover_color)
    db.add(book)
    db.commit()
    db.refresh(book)
    return _book_read(db, book)


@router.get("/books/{book_id}", response_model=BookRead)
def get_book(book_id: str, db: Session = Depends(get_db)) -> BookRead:
    return _book_read(db, _get_book(db, book_id))


@router.patch("/books/{book_id}", response_model=BookRead)
def patch_book(book_id: str, payload: BookPatch, db: Session = Depends(get_db)) -> BookRead:
    book = _get_book(db, book_id)
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(book, key, value)
    book.updated_at = utc_now()
    db.commit()
    db.refresh(book)
    return _book_read(db, book)


@router.delete("/books/{book_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_book(book_id: str, db: Session = Depends(get_db)) -> Response:
    book = _get_book(db, book_id)
    db.delete(book)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/books/{book_id}/touch", status_code=status.HTTP_204_NO_CONTENT)
def touch_book(book_id: str, db: Session = Depends(get_db)) -> Response:
    book = _get_book(db, book_id)
    book.last_opened_at = utc_now()
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/books/{book_id}/export")
def export_book(
    book_id: str,
    format: ExportFormat = Query(default="markdown"),
    include_drafts: bool = Query(default=False),
    db: Session = Depends(get_db),
) -> Response:
    """Export an entire book as Markdown or plain text.

    See PROJECT_PLAN §5.F for the layout decisions. By default only
    ``finalized`` chapters are included — pass ``include_drafts=true``
    to also dump everything still in draft.

    The response body is the raw text (NOT wrapped in JSON), the
    ``Content-Type`` matches the selected format (``text/markdown`` or
    ``text/plain``) and the ``Content-Disposition`` header carries an
    RFC 5987 ``filename*`` so non-ASCII book titles (i.e. Chinese)
    survive every browser/Mac client.
    """
    book = _get_book(db, book_id)
    chapters = list(
        db.scalars(
            select(Chapter).where(Chapter.book_id == book.id).order_by(Chapter.index)
        ).all()
    )

    if format == "markdown":
        body = export_book_markdown(book, chapters, include_drafts=include_drafts)
        media_type = "text/markdown; charset=utf-8"
        extension = "md"
    else:
        body = export_book_txt(book, chapters, include_drafts=include_drafts)
        media_type = "text/plain; charset=utf-8"
        extension = "txt"

    filename = build_filename(book.title, extension)
    return Response(
        content=body,
        media_type=media_type,
        headers={"Content-Disposition": build_content_disposition(filename)},
    )


def _get_book(db: Session, book_id: str) -> Book:
    book = db.get(Book, book_id)
    if book is None:
        raise i18n_not_found("book")
    return book


def _book_read(db: Session, book: Book) -> BookRead:
    chapter_count = db.scalar(select(func.count()).select_from(Chapter).where(Chapter.book_id == book.id)) or 0
    character_count = db.scalar(select(func.count()).select_from(Character).where(Character.book_id == book.id)) or 0
    return BookRead.model_validate(
        {
            "id": book.id,
            "title": book.title,
            "cover_color": book.cover_color,
            "world_setting": book.world_setting,
            "chapter_count": chapter_count,
            "character_count": character_count,
            "created_at": book.created_at,
            "updated_at": book.updated_at,
            "last_opened_at": book.last_opened_at,
        }
    )
