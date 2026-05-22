from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict

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
    created_at: datetime


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
    created_at: datetime
