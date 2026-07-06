from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator

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
    # 审后修复 🟡#1 — ``min_length=1`` only bites when ``name`` is actually
    # present in the request body (PATCH uses ``exclude_unset``, so an
    # omitted/``None``-default field never reaches here). It rejects the
    # explicit-empty-string case (`{"name": ""}`) while leaving "don't touch
    # name" (field absent) and "clear role" (`{"role": ""}`, still legal)
    # untouched.
    name: str | None = Field(default=None, min_length=1)
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


# v1.3.0 (II) P2 — "导入人物卡" upgraded from "one name per line → blank
# card" to "paste full character-sheet prose → LLM parse → land cards".
class CharacterParseRequest(BaseModel):
    raw_text: str = Field(min_length=1, max_length=50000)

    @field_validator("raw_text")
    @classmethod
    def _reject_whitespace_only(cls, value: str) -> str:
        # ``min_length=1`` only bounds character count, so a string of pure
        # whitespace (spaces/newlines) would otherwise slip through as
        # "non-empty". Plan §4 P2 requires 422 for "空/纯空白".
        if not value.strip():
            raise ValueError("raw_text 不能为空或纯空白")
        return value
