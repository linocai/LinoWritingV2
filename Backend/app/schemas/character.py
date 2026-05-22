from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class CharacterCreate(BaseModel):
    name: str
    role: str | None = None
    frozen_fields: dict[str, Any] = Field(default_factory=dict)
    live_fields: dict[str, Any] = Field(default_factory=dict)


class CharacterPatch(BaseModel):
    name: str | None = None
    role: str | None = None
    frozen_fields: dict[str, Any] | None = None
    live_fields: dict[str, Any] | None = None


class CharacterRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    book_id: str
    name: str
    role: str | None
    frozen_fields: dict[str, Any]
    live_fields: dict[str, Any]
    created_at: datetime
    updated_at: datetime
