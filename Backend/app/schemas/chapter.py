from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict

from app.schemas.structured_prompt import StructuredPrompt

ChapterStatus = Literal["draft", "prompt_ready", "writing", "draft_ready", "finalized"]


class ChapterCreate(BaseModel):
    user_prompt: str
    title: str | None = None


class ChapterPatch(BaseModel):
    title: str | None = None
    user_prompt: str | None = None
    structured_prompt: StructuredPrompt | None = None
    draft_text: str | None = None


class ChapterSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    index: int
    title: str | None
    status: ChapterStatus
    updated_at: datetime


class ChapterRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    book_id: str
    index: int
    title: str | None
    user_prompt: str | None
    structured_prompt: dict[str, Any] | None
    draft_text: str | None
    summary: str | None
    status: ChapterStatus
    created_at: datetime
    updated_at: datetime
