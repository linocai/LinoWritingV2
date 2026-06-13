from __future__ import annotations

from pydantic import BaseModel, ConfigDict, field_validator

from app.schemas.common import UtcDatetime


class AgentPersonaRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    agent_role: str
    system_prompt: str
    is_default: bool
    updated_at: UtcDatetime


class AgentPersonaUpdate(BaseModel):
    """Body for ``PATCH /agent-personas/{role}``.

    ``system_prompt`` must be non-empty (an empty / whitespace-only string is
    a 422 — the validator below rejects it before the handler runs). Mirrors
    plan §5.4: "空串→422 validation".
    """

    system_prompt: str

    @field_validator("system_prompt")
    @classmethod
    def _non_empty(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("system_prompt must not be empty")
        return value
