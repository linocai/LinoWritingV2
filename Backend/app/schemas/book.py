from __future__ import annotations

from pydantic import BaseModel, ConfigDict

from app.schemas.common import UtcDatetime


class BookCreate(BaseModel):
    title: str
    cover_color: str | None = None


class BookPatch(BaseModel):
    title: str | None = None
    cover_color: str | None = None
    world_setting: str | None = None


class BookRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    cover_color: str | None
    world_setting: str | None
    chapter_count: int
    character_count: int
    created_at: UtcDatetime
    updated_at: UtcDatetime
    last_opened_at: UtcDatetime | None
