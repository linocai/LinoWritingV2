from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient
from app.schemas.structured_prompt import StructuredPrompt
from app.services.personas import DEFAULT_PERSONAS, compose_system

# v0.7 §5.L.4 — Expander now infers 0-2 ``focus_traits`` per chapter so the
# Writer prompt has a concrete steering signal instead of treating every trait
# in every character card as equally important. Hard-cap at 2 because empirical
# testing shows 3+ traits push the Writer back into "checklist mode" — the
# exact failure we're trying to fix in §5.L.
MAX_FOCUS_TRAITS = 2


class PromptExpanderAgent:
    # Fixed expansion mechanics. The persona ([人格]/[原则]/[边界], DB-stored &
    # App-editable) is resolved by ``get_persona(db, 'expander')`` at the router
    # and composed in front of these rules at runtime (see ``compose_system``).
    #
    # v1.4.0 (MM) P1 — 优化师降职: v1.3.3/v1.3.4 的字数/断原文快修治好了素材
    # 污染，但作者审出了更深的**权威倒置**——Expander 的 200-300 字
    # ``chapter_directive`` 在质感/笔触层二次创作、Writer 把它当最高指令而
    # 作者的 ``chapter.user_prompt`` 原文反而缺席，违背"只文学化作者输入"的
    # 红线。``chapter_directive`` 整条链路（schema 字段/这里的产出职责/
    # Writer 的读取）全部删除；作者的 ``chapter.user_prompt`` 现在直接是
    # Writer 的最高权威输入（见 ``context_pack.build_writer_context`` /
    # ``agents.writer``），不再需要 Expander 居中蒸馏一份"方向盘"。
    # Expander 降职为**结构员 + 校对员**，只剩三件事：①收束结构 ②连续性/
    # 矛盾校对（输出 continuity_alerts 给作者看，不改作者原文）③框定范围。
    # 它依然绝不发明作者没写的情节——这条红线不变，只是不再"蒸馏指令"这件事
    # 本身被认定为二次创作，删除。
    #
    # v1.3.2 (LL) P3 — 记忆第三层「一句话大事记」: the summary tier is now
    # itself bounded (``RECENT_SUMMARY_COUNT``), with anything older still
    # mechanically distilled into ``recent_headlines`` (one-line 一句话大事记
    # per chapter, ``context_pack._distill_headline``) instead of fed as full
    # summary forever. This keeps long-range continuity checking possible on
    # very long books without unbounded per-chapter token growth.
    OPERATIONAL_RULES = """
你是一个中文小说的章节结构员兼校对员。
just-in-time 读「三类输入」现切本章：① 你的人格（system 前段）；
② 相关记忆切片 —— world_setting（全书世界观设定，规则性设定的唯一权威）、
   involved_characters（在场角色卡 + 近期时间线）与三层记忆：
   recent_fulltext（最近 3 章已完成章节的原文全文，用于精细连续性核对）+
   recent_summaries（再往前一段已完成章节的完整梗概，动态，由档案员每章回写）+
   recent_headlines（更早所有章节的一句话大事记，每章一行，用于长程连续性——
   知道"很久以前发生过什么"，但不需要逐句细节）；
   ③ chapter.user_prompt —— 作者写的本章剧情完整叙述（一段话，本章节 Bible，
   描述这一章要发生的事，是全流程的最高权威）。

你只做三件事，**不做第四件**——不代替作者改写 user_prompt，不往里加你自己的
文笔或二次创作：

1. **收束结构**：把作者的本章叙述拆解、归类进既有结构化字段——chapter_goal /
   must_happen / must_not_happen / scene_setting / narrative_pov /
   characters_involved / focus_traits / target_word_count。只做归类整理，
   **不要发明任何新字段，也不要发明作者叙述里没有的内容**。
2. **连续性/矛盾校对**：对照 world_setting（世界观硬约束）与三层记忆
   （recent_fulltext 最近 3 章原文 + recent_summaries 再往前的完整梗概 +
   recent_headlines 更早的一句话大事记），核对本章叙述与世界观、前文事实、
   角色当前状态是否存在缺口或矛盾。发现问题时，把提醒写进
   continuity_alerts（字符串数组，每条一句话，点明具体冲突或缺口在哪）——
   这是**给作者看的提醒**，不是要你去"修复"，绝不擅自改动或续写作者的
   本章叙述来消除矛盾。**recent_fulltext / recent_summaries /
   recent_headlines 都为空时**（第一章，或还没有前文）跳过前文连续性核对，
   只做结构化 + 世界观核对，continuity_alerts 留空。
3. **框定范围**：核实本章要承接的落点（前文悬而未决的伏笔、角色当前状态）
   确实被 chapter_goal / scene_setting 覆盖到；把作者叙述里隐含的边界
   （明确不该发生的事、不该被提前揭示的信息）显式写进 must_not_happen，
   帮 Writer 在文笔与细节发挥时守住边界，而不是替 Writer 决定怎么写。

红线：**不发明任何作者没写的情节**——你只结构化、核对、框定作者已经写下的
内容，绝不新增剧情，也绝不代替作者改写 chapter.user_prompt 本身。

必须从 all_characters 里选择 characters_involved，且只使用角色 id。
must_happen / must_not_happen 必须具体、可验证，且来自作者的本章叙述。
风格参考 style_directive；如果为空，不要自行发明额外风格约束。
extra_notes 是作者自己的补充说明通道——你不主动往里写内容，留空即可。

# focus_traits（本章重点 emerge 的角色特质）
从 characters_involved 涉及角色的 frozen_fields / author_notes 池里，
挑 0-2 个本章最相关的 trait 放进 focus_traits。
- 内容是"trait 名"的纯字符串（如 "谨慎"、"对妹妹的愧疚"），
  不是字段路径（不要写成 "core_traits.谨慎"）。
- 不要挑超过 2 个 — 让 Writer 聚焦。
- 如果本章场景不需要任何 trait 重点（纯过场 / 纯动作场），返回空数组。
- 选择标准：哪些特质在本章的抉择/冲突里会真正驱动角色行为。

最低要求：chapter_goal 必须非空。
""".strip()

    # Backward-compat / regression surface: the default-composed system prompt.
    system_prompt = compose_system(DEFAULT_PERSONAS["expander"], OPERATIONAL_RULES)

    def __init__(self, llm: LLMClient, persona: str | None = None) -> None:
        self.llm = llm
        self.system_prompt = compose_system(
            persona if persona is not None else DEFAULT_PERSONAS["expander"],
            self.OPERATIONAL_RULES,
        )

    def expand(self, context: dict[str, Any]) -> dict[str, Any]:
        # v0.6+: model selection follows the active ProviderKey's ``model_name``;
        # the old per-agent ``model_name_fast`` override has been removed.
        result = self.llm.complete_json(
            system=self.system_prompt,
            user=json.dumps(context, ensure_ascii=False, default=str),
            schema=_expander_json_schema(),
            temperature=0.4,
        )
        # §5.L.4 defensive truncate — Expander system_prompt already says
        # "max 2", but LLMs over-deliver on lists. We truncate server-side
        # before Pydantic validation so the contract is enforced regardless
        # of which model is behind the LLM client.
        if isinstance(result, dict) and isinstance(result.get("focus_traits"), list):
            result["focus_traits"] = [
                trait for trait in result["focus_traits"] if isinstance(trait, str)
            ][:MAX_FOCUS_TRAITS]
        # v1.4.0 (MM) P1 — same defensive shape for the new continuity_alerts
        # list: keep only non-empty strings, no length cap (unlike
        # focus_traits — a chapter may legitimately surface several distinct
        # continuity gaps).
        if isinstance(result, dict) and isinstance(result.get("continuity_alerts"), list):
            result["continuity_alerts"] = [
                alert.strip()
                for alert in result["continuity_alerts"]
                if isinstance(alert, str) and alert.strip()
            ]
        # 审后修复 🔵 (archive/REVIEW_REPORT_v1.4.0.md) — ``extra="allow"`` means
        # a model that ignores OPERATIONAL_RULES could still smuggle a dead
        # ``chapter_directive`` key back into a NEW chapter's structured_prompt
        # (old chapters keep the key from before this schema-deletion — that's
        # fine and expected; this pop is only about NOT letting a live LLM call
        # resurrect it). Pop it before validation so it never survives into the
        # persisted prompt, on ANY expand() call, model-compliant or not.
        if isinstance(result, dict):
            result.pop("chapter_directive", None)
        prompt = StructuredPrompt.model_validate(result).model_dump(exclude_none=True)
        if not (prompt.get("chapter_goal") or "").strip():
            raise ValueError("Expander output missing non-empty chapter_goal")
        # v1.4.0 (MM) P1 决议 #1 — re-expand 不覆盖作者已填 extra_notes.
        # 审后修复 🟡2 (archive/REVIEW_REPORT_v1.4.0.md): the original version of
        # this guard only fired when THIS call's output left extra_notes empty
        # — so an author-filled note could still be clobbered by a model that
        # (against OPERATIONAL_RULES) also filled the field. ``extra_notes`` is
        # a pure author-owned channel (P1 决议 #1); once the author has written
        # something there, it wins UNCONDITIONALLY over whatever this expand()
        # call's LLM output contains — the model never gets to overwrite it,
        # compliant or not. Only when the author has NOTHING existing yet does
        # this call's own (LLM) output get a chance to populate the field.
        existing_extra_notes = context.get("existing_extra_notes")
        if isinstance(existing_extra_notes, str) and existing_extra_notes.strip():
            prompt["extra_notes"] = existing_extra_notes
        elif not (prompt.get("extra_notes") or "").strip():
            prompt.pop("extra_notes", None)
        return prompt


def _expander_json_schema() -> dict[str, Any]:
    """JSON schema handed to ``complete_json``.

    Extends ``StructuredPrompt.model_json_schema()`` with an explicit
    ``focus_traits`` slot so models that respect schema (OpenAI / Claude with
    structured outputs) know to emit it. ``maxItems: 2`` matches the
    server-side truncate in :func:`PromptExpanderAgent.expand`.
    """
    schema = StructuredPrompt.model_json_schema()
    properties = schema.setdefault("properties", {})
    properties["focus_traits"] = {
        "type": "array",
        "items": {"type": "string"},
        "default": [],
        "maxItems": MAX_FOCUS_TRAITS,
        "description": (
            "0-2 trait names this chapter may 重点 emerge. Plain strings "
            "(e.g. '谨慎'), not field paths."
        ),
    }
    # v1.4.0 (MM) P1 — continuity/contradiction notes FOR THE AUTHOR (never
    # read by the Writer — see ``writer._render_task_block``). Replaces the
    # deleted ``chapter_directive`` slot as the model-facing guardrail
    # description: this is a note, not an instruction, and never a rewrite of
    # the author's own narrative.
    properties["continuity_alerts"] = {
        "type": "array",
        "items": {"type": "string"},
        "default": [],
        "description": (
            "0+ one-sentence continuity/contradiction notes FOR THE AUTHOR — "
            "gaps or conflicts between this chapter's narrative and "
            "world_setting / the three memory tiers. NEVER a rewrite or "
            "'fix' of the author's own chapter narrative; this agent never "
            "invents plot. Empty when nothing conflicts (including on the "
            "first chapter, where there is no prior memory to check against)."
        ),
    }
    # v1.4.0 (MM) P1 决议 #1 — extra_notes reverted to a pure author channel:
    # the Expander should leave it blank; the server preserves whatever the
    # author already typed when this call's output is empty (see
    # ``PromptExpanderAgent.expand``).
    properties["extra_notes"] = {
        "type": ["string", "null"],
        "description": (
            "Author-owned supplementary notes channel. Leave this null/empty "
            "— do not author content here; any existing author-written value "
            "is preserved server-side regardless of what this field returns."
        ),
    }
    return schema
