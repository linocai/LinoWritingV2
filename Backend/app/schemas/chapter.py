from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import UtcDatetime
from app.schemas.structured_prompt import StructuredPrompt

ChapterStatus = Literal["draft", "prompt_ready", "writing", "draft_ready", "finalized"]
ChapterSource = Literal["agent", "imported"]


class ChapterCreate(BaseModel):
    user_prompt: str
    title: str | None = None


class ChapterPatch(BaseModel):
    title: str | None = None
    user_prompt: str | None = None
    structured_prompt: StructuredPrompt | None = None
    draft_text: str | None = None


class ChapterImportRequest(BaseModel):
    draft_text: str = Field(..., min_length=1)
    title: str | None = None
    summary: str | None = None
    run_extractor: bool = True


# v0.7 §5.P.1 E — admin_reset escape hatch.
# Used when a chapter is stuck in ``writing`` (SSE crashed, client died,
# server restart mid-stream) and the user has no other way out. Only
# states that the chapter could legitimately reach via the normal flow
# are permitted as targets — ``writing`` (would re-stick) and
# ``finalized`` (use /reopen instead) are excluded.
AdminResetTarget = Literal["draft", "prompt_ready", "draft_ready"]


class ChapterAdminResetRequest(BaseModel):
    target_status: AdminResetTarget = "draft_ready"


class ChapterSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    index: int
    title: str | None
    status: ChapterStatus
    source: ChapterSource
    updated_at: UtcDatetime


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
    source: ChapterSource
    created_at: UtcDatetime
    updated_at: UtcDatetime
