from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class AgentPersona(Base):
    """v1.0.0 EE Phase 1 — DB-stored, App-editable persona prompt per Agent.

    ``agent_role`` ∈ {expander, writer, extractor} (aligns with the
    ``AgentRole`` Literal in app/schemas/provider_key.py). ``system_prompt``
    is the persona currently in effect, read at runtime by each Agent.
    ``is_default`` is true while the row is still the seeded default and
    flips to false once the author edits it; ``reset`` writes the code-level
    ``DEFAULT_PERSONAS`` constant back and restores ``is_default=true``.

    See archive/v1.0.0_plan.md §3.3 / §4.4. Single-user app → no version
    history (plain-text overwrite + reset is enough).
    """

    __tablename__ = "agent_personas"

    agent_role: Mapped[str] = mapped_column(String(32), primary_key=True)
    system_prompt: Mapped[str] = mapped_column(Text, nullable=False)
    is_default: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )
