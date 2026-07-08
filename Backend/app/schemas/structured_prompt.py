from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StructuredPrompt(BaseModel):
    model_config = ConfigDict(extra="allow")

    # v1.5.0 (NN) P1 — 优化师终极精简 (框架员+选角员+领读员): renamed from
    # ``must_happen``. Definition changed from a "验收清单" (acceptance
    # checklist the Writer must tick off) to a "领读注解" (a guided-reading
    # annotation that helps the Writer understand the author's Bible) — see
    # ``agents.prompt_expander.OPERATIONAL_RULES`` / ``agents.writer``. Old
    # chapters whose stored JSON still has the old ``must_happen`` key keep
    # decoding fine via ``extra="allow"`` below (ignored, never migrated;
    # re-expanding a chapter produces ``plot_anchors`` fresh).
    plot_anchors: list[str] = Field(default_factory=list)
    characters_involved: list[str] = Field(default_factory=list)
    scene_setting: str | None = None
    narrative_pov: Literal[
        "first_person",
        "third_person_limited",
        "third_person_omniscient",
    ] | None = None
    target_word_count: int | None = Field(default=None, gt=0)
    # v1.5.0 (NN) P1 — new 领读员 output: a ONE-LINE (<=50 字) note on this
    # chapter's style micro-adjustment (sentence length/rhythm, narrative
    # pace, word density, narrative temperature). Server-side truncated to 50
    # chars in ``PromptExpanderAgent.expand``; author-editable in Step2.
    # Replaces the retired global ``style_directive`` channel as the Writer's
    # per-chapter style input (see ``agents.writer._render_user_message``).
    chapter_style: str | None = None
    # v1.4.0 (MM) P1 决议 #1 — the Expander's ONE remaining "steering-adjacent"
    # output: not direction for the Writer, but a continuity/contradiction
    # note FOR THE AUTHOR (gaps or conflicts against world_setting / the three
    # memory tiers). The Writer never reads this key (enforced by
    # ``writer._render_task_block`` simply never looking at it). v1.5.0 (NN)
    # P1 定案 #5: kept unchanged.
    continuity_alerts: list[str] = Field(default_factory=list)

    # v1.5.0 (NN) P1 定案 #1 — ``chapter_goal`` / ``must_not_happen`` /
    # ``extra_notes`` / ``focus_traits`` are DELETED (schema fields + the
    # ``require_chapter_goal`` validator that used to guard ``chapter_goal``).
    # No compensating rule is added anywhere downstream — negative
    # instructions (must_not_happen) are not folded into the Bible, and no
    # substitute guardrail replaces focus_traits/extra_notes. Old chapters
    # whose stored JSON still has any of these keys keep decoding fine via
    # ``extra="allow"`` above (ignored, never migrated, never read again by
    # any agent).
