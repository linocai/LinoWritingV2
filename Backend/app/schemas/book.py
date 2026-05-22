from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict


class BookCreate(BaseModel):
    title: str
    cover_color: str | None = None


class BookPatch(BaseModel):
    title: str | None = None
    cover_color: str | None = None
    world_setting: str | None = None
    style_directive: str | None = None


class BookRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    cover_color: str | None
    world_setting: str | None
    style_directive: str | None
    chapter_count: int
    character_count: int
    created_at: datetime
    updated_at: datetime
    last_opened_at: datetime | None
