from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import UtcDatetime


class CharacterCreate(BaseModel):
    name: str
    role: str | None = None
    frozen_fields: dict[str, Any] = Field(default_factory=dict)
    live_fields: dict[str, Any] = Field(default_factory=dict)
    # v0.7 §5.L.3 — author's private "cheat sheet" notes; whole-object replace
    # semantics on PATCH, same as frozen_fields / live_fields.
    author_notes: dict[str, Any] = Field(default_factory=dict)


class CharacterPatch(BaseModel):
    name: str | None = None
    role: str | None = None
    frozen_fields: dict[str, Any] | None = None
    live_fields: dict[str, Any] | None = None
    author_notes: dict[str, Any] | None = None


class CharacterRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    book_id: str
    name: str
    role: str | None
    frozen_fields: dict[str, Any]
    live_fields: dict[str, Any]
    author_notes: dict[str, Any] = Field(default_factory=dict)
    # v0.7 §5.B (Phase B-fld) — read-only field-level highlight state.
    # Cleared automatically by ``PATCH /characters/{id}`` for each key
    # touched in ``live_fields``. NOT exposed in CharacterPatch; clearing
    # is a server-side side-effect of the canonical edit path.
    pending_field_highlights: dict[str, Any] = Field(default_factory=dict)
    created_at: UtcDatetime
    updated_at: UtcDatetime
