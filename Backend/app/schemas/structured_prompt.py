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

    @model_validator(mode="after")
    def require_chapter_goal(self) -> "StructuredPrompt":
        if not (self.chapter_goal or "").strip():
            raise ValueError("chapter_goal must be non-empty")
        return self
