from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.ext.mutable import MutableDict
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.common import json_dict_type, utc_now


class Character(Base):
    __tablename__ = "characters"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[str | None] = mapped_column(Text)
    frozen_fields: Mapped[dict[str, Any]] = mapped_column(
        MutableDict.as_mutable(json_dict_type),
        default=dict,
        nullable=False,
    )
    live_fields: Mapped[dict[str, Any]] = mapped_column(
        MutableDict.as_mutable(json_dict_type),
        default=dict,
        nullable=False,
    )
    # v0.7 §5.L.3 — author's "actor cheat sheet" (motivation, past wounds,
    # secrets). Writer reads it for understanding but MUST NOT narrate it
    # directly (enforced via Writer system prompt in L-2).
    author_notes: Mapped[dict[str, Any]] = mapped_column(
        MutableDict.as_mutable(json_dict_type),
        default=dict,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )

    book = relationship("Book", back_populates="characters")
    timeline_events = relationship("TimelineEvent", back_populates="character", cascade="all, delete-orphan")
