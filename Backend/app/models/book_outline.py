from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class BookOutline(Base):
    """v1.0.0 EE Phase 1 — the ~5000-word plain-prose outline for a book.

    Singleton per book (``book_id`` is UNIQUE): 1 book : 1 outline. Stores
    the author-supplied prose verbatim — V1 does **not** structurally parse
    or "digest" it (no arc_beats / foreshadowing / digested_at). The outline
    is a *living* document that only changes when the author edits it
    (PATCH); the Expander reads the whole ``raw_text`` just-in-time each
    chapter. See PROJECT_PLAN §4 + archive/v1.0.0_plan.md §3.1.
    """

    __tablename__ = "book_outlines"
    __table_args__ = (UniqueConstraint("book_id", name="uq_book_outlines_book_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    book_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("books.id", ondelete="CASCADE"),
        nullable=False,
    )
    raw_text: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )
