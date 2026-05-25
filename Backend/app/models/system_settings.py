from __future__ import annotations

from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class SystemSettings(Base):
    __tablename__ = "system_settings"
    __table_args__ = (CheckConstraint("id = 1", name="ck_system_settings_singleton"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=False)
    active_provider_key_id: Mapped[str | None] = mapped_column(
        String(36),
        ForeignKey("provider_keys.id", ondelete="SET NULL"),
        nullable=True,
    )
    # v0.7 M-1: per-Agent active pointers. NULL = no agent-specific override
    # → factory falls back to ``active_provider_key_id`` (v0.6 behavior).
    # Each is constrained to a single provider_keys row by FK; ON DELETE
    # SET NULL keeps the singleton row consistent if a key is deleted.
    active_writer_key_id: Mapped[str | None] = mapped_column(
        String(36),
        ForeignKey("provider_keys.id", ondelete="SET NULL"),
        nullable=True,
    )
    active_extractor_key_id: Mapped[str | None] = mapped_column(
        String(36),
        ForeignKey("provider_keys.id", ondelete="SET NULL"),
        nullable=True,
    )
    active_expander_key_id: Mapped[str | None] = mapped_column(
        String(36),
        ForeignKey("provider_keys.id", ondelete="SET NULL"),
        nullable=True,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )
