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
    # v1.4.0 (MM) P1 决议 #1: ``extra_notes`` 回归纯作者补充说明 —— Expander
    # 不再主动往这里写内容（见 prompt_expander.OPERATIONAL_RULES），只作为
    # 作者手填的 PATCH 通道保留；``PromptExpanderAgent.expand`` 在 LLM 输出
    # 为空时保留调用前 chapter.structured_prompt 里作者已填的原值，防止
    # re-expand 悄悄把它清空。
    extra_notes: str | None = None
    # v0.7 §5.L.3 — 0-2 trait names the chapter is allowed to "重点 emerge".
    # Populated by Expander in L-2 (not yet — L-1 only opens the schema slot);
    # authors may edit it via the chapter PATCH endpoint. Free-form strings,
    # not validated against any registry — the Writer prompt treats them as
    # narrative hints, not strict tags.
    focus_traits: list[str] = Field(default_factory=list)
    # v1.4.0 (MM) P1 — 优化师降职: ``chapter_directive`` (the 200-300 字
    # steering "方向盘") is DELETED. The author's own ``chapter.user_prompt``
    # is now the Writer's highest-authority input directly (see
    # ``context_pack.build_writer_context`` / ``agents.writer``) — no more
    # Expander-authored directive standing in front of it. Old chapters whose
    # stored JSON still has a ``chapter_directive`` key keep decoding fine via
    # ``extra="allow"`` below (ignored, never migrated, never read again).
    #
    # ``continuity_alerts`` replaces it as the Expander's ONE remaining
    # "steering-adjacent" output: not direction for the Writer, but a
    # continuity/contradiction note FOR THE AUTHOR (gaps or conflicts against
    # world_setting / the three memory tiers). The Writer never reads this key
    # (enforced by ``writer._render_task_block`` simply never looking at it).
    continuity_alerts: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def require_chapter_goal(self) -> "StructuredPrompt":
        if not (self.chapter_goal or "").strip():
            raise ValueError("chapter_goal must be non-empty")
        return self
