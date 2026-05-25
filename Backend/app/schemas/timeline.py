from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.schemas.common import UtcDatetime

TimelineEventType = Literal[
    "action",
    "experience",
    "relation_change",
    "secret_learned",
    "ability_gained",
    "state_change",
]


class TimelineEventRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    book_id: str
    character_id: str
    chapter_id: str
    chapter_index: int
    event_type: TimelineEventType
    event_text: str
    created_at: UtcDatetime
    # v0.7 §5.C — None for Agent-original rows, set on every user PATCH.
    edited_at: UtcDatetime | None = None


class TimelineEventPatch(BaseModel):
    """Body for ``PATCH /api/v1/timeline_events/{id}``.

    Deliberately only exposes ``event_text`` and ``event_type``. ``character_id``
    and ``chapter_id`` are NOT patchable because moving an event across chapters
    or characters would corrupt the timeline semantics (each event belongs to
    the chapter where it was extracted). Unknown / disallowed keys are silently
    dropped at the Pydantic layer by default ``extra='ignore'`` and re-asserted
    by a router-level allowlist (mirrors the chapters PATCH pattern from
    §5.P.1 F).
    """

    event_text: str | None = Field(default=None, min_length=1)
    event_type: TimelineEventType | None = None

    @model_validator(mode="after")
    def require_at_least_one_field(self) -> "TimelineEventPatch":
        if self.event_text is None and self.event_type is None:
            # v0.7 §5.N decision: this validator runs inside Pydantic's
            # RequestValidationError → kind=validation envelope, which
            # the frontend treats as a schema-level (developer-facing)
            # signal — the C-tl inline editor never sends an empty patch.
            # Kept English on purpose so a debug surface stays a debug
            # surface; user-visible errors live in app/errors.py templates.
            raise ValueError(
                "TimelineEventPatch requires at least one of event_text / event_type"
            )
        return self


class AgentLogRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    chapter_id: str | None
    agent_name: str
    input_preview: str | None
    output_preview: str | None
    latency_ms: int | None
    tokens_in: int | None
    tokens_out: int | None
    error: str | None
    created_at: UtcDatetime
