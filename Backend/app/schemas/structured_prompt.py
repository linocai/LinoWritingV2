from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StructuredPrompt(BaseModel):
    model_config = ConfigDict(extra="allow")

    chapter_goal: str | None = None
    must_happen: list[str] = Field(default_factory=list)
    must_not_happen: list[str] = Field(default_factory=list)
    characters_involved: list[str] = Field(default_factory=list)
    scene_setting: str | None = None
    narrative_pov: Literal[
        "first_person",
        "third_person_limited",
        "third_person_omniscient",
    ] | None = None
    target_word_count: int | None = Field(default=None, gt=0)
    extra_notes: str | None = None
    # v0.7 §5.L.3 — 0-2 trait names the chapter is allowed to "重点 emerge".
    # Populated by Expander in L-2 (not yet — L-1 only opens the schema slot);
    # authors may edit it via the chapter PATCH endpoint. Free-form strings,
    # not validated against any registry — the Writer prompt treats them as
    # narrative hints, not strict tags.
    focus_traits: list[str] = Field(default_factory=list)
    # v1.0.0 EE Phase 2 (§5.3) — the Expander's 200-300 字「本章创作指令」.
    # Plain prose, optional (decodeIfPresent on the App side for old chapters).
    # P1 红线: this is STEERING (direction / tension), never character-card or
    # timeline KNOWLEDGE — that reaches the Writer via Context Pack. The
    # Expander system prompt + the JSON-schema description enforce the boundary;
    # this field just carries the result and is editable via the chapter PATCH
    # whitelist (structured_prompt is already patchable).
    chapter_directive: str | None = None

    @model_validator(mode="after")
    def require_chapter_goal(self) -> "StructuredPrompt":
        if not (self.chapter_goal or "").strip():
            raise ValueError("chapter_goal must be non-empty")
        return self
