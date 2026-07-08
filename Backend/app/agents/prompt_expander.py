from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient
from app.schemas.structured_prompt import StructuredPrompt
from app.services.personas import DEFAULT_PERSONAS, compose_system

# v1.5.0 (NN) P1 — hard cap (Chinese characters) on the new ``chapter_style``
# 领读员 output. Server-side truncate in ``PromptExpanderAgent.expand`` — the
# rules already say "≤50 字" but LLMs over-deliver on free-text fields just
# like they used to on the (now deleted) ``focus_traits`` lists.
CHAPTER_STYLE_MAX_CHARS = 50


class PromptExpanderAgent:
    # Fixed expansion mechanics. The persona ([人格]/[原则]/[边界], DB-stored &
    # App-editable) is resolved by ``get_persona(db, 'expander')`` at the router
    # and composed in front of these rules at runtime (see ``compose_system``).
    #
    # v1.5.0 (NN) P1 — 优化师终极精简: v1.4.0 已经删了 ``chapter_directive``
    # 治好权威倒置，但剩下的结构化字段（chapter_goal/must_not_happen/
    # focus_traits/extra_notes）大多仍是"验收清单"式的二次约束，继续把 Writer
    # 从"据作者 Bible 发挥"拽回"逐条打勾"。作者定案把 Expander 终极精简为
    # **框架员 + 选角员 + 领读员**三重身份：①框架——只提炼 scene_setting /
    # narrative_pov / target_word_count；②选角——从 all_characters 里选出
    # characters_involved；③领读——产出 plot_anchors（帮 Writer 读懂 Bible 的
    # 领读注解，不是验收清单，由 ``must_happen`` 改名而来）+ chapter_style
    # （≤50 字本章文风微调，三道笼子见规则正文）+ continuity_alerts（连续性
    # 校对，保留不动）。chapter_goal/must_not_happen/focus_traits/extra_notes
    # 四个字段全部删除，不做任何补偿性规则（否定句不搬进 Bible）。
    #
    # v1.3.2 (LL) P3 — 记忆第三层「一句话大事记」: the summary tier is now
    # itself bounded (``RECENT_SUMMARY_COUNT``), with anything older still
    # mechanically distilled into ``recent_headlines`` (one-line 一句话大事记
    # per chapter, ``context_pack._distill_headline``) instead of fed as full
    # summary forever. This keeps long-range continuity checking possible on
    # very long books without unbounded per-chapter token growth.
    OPERATIONAL_RULES = """
你是一个中文小说的章节框架员、选角员兼领读员。
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

1. **搭框架**：从作者的本章叙述里提炼 scene_setting（场景）/ narrative_pov
   （视角）/ target_word_count（目标字数）。只做提炼整理，**不要发明任何
   新字段，也不要发明作者叙述里没有的内容**。
2. **选角**：从 all_characters 里挑出本章真正在场、Writer 需要参考卡片的
   角色，填进 characters_involved（只使用角色 id）。
3. **领读**：把作者本章叙述里最关键、Writer 不能漏写的情节节点提炼成
   plot_anchors（字符串数组）——这是**帮 Writer 读懂 Bible 的领读注解**，
   不是逐条打勾的验收清单，数量宁少不多，只挑真正的骨架节点。同时生成
   chapter_style——一句话（≤50 字）描述本章文风的具体微调，**只谈句式长短、
   叙事节奏快慢、用词密度、叙事温度冷热这类纯文字层面的东西，绝不涉及任何
   情节内容或具体意象**：
   - 反例（情节/意象，禁止）："写出他内心的挣扎与释然"、"渲染雨夜的压抑感"。
   - 正例（纯文风，允许）："短句为主，节奏偏快，用词克制冷静"、
     "长句铺陈，叙事温度偏冷"。
   若本章无需特别的文风微调，留空（Writer 会遵循人格里的整体文风底色）。
   此外，对照 world_setting（世界观硬约束）与三层记忆（recent_fulltext 最近
   3 章原文 + recent_summaries 再往前的完整梗概 + recent_headlines 更早的
   一句话大事记），核对本章叙述与世界观、前文事实、角色当前状态是否存在
   缺口或矛盾。发现问题时，把提醒写进 continuity_alerts（字符串数组，每条
   一句话，点明具体冲突或缺口在哪）——这是**给作者看的提醒**，不是要你去
   "修复"，绝不擅自改动或续写作者的本章叙述来消除矛盾。**recent_fulltext /
   recent_summaries / recent_headlines 都为空时**（第一章，或还没有前文）
   跳过前文连续性核对，只做框架 + 选角 + 领读 + 世界观核对，continuity_alerts
   留空。

红线：**不发明任何作者没写的情节**——你只搭框架、选角、领读、核对作者已经
写下的内容，绝不新增剧情，也绝不代替作者改写 chapter.user_prompt 本身。

必须从 all_characters 里选择 characters_involved，且只使用角色 id。
plot_anchors 必须具体、可验证，且来自作者的本章叙述。
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
        # v1.4.0 (MM) P1 决议 — defensive shape for continuity_alerts: keep
        # only non-empty strings, no length cap (a chapter may legitimately
        # surface several distinct continuity gaps). v1.5.0 (NN) P1: kept
        # unchanged.
        if isinstance(result, dict) and isinstance(result.get("continuity_alerts"), list):
            result["continuity_alerts"] = [
                alert.strip()
                for alert in result["continuity_alerts"]
                if isinstance(alert, str) and alert.strip()
            ]
        # v1.5.0 (NN) P1 定案 #3 — 笼子①: chapter_style 硬上限
        # CHAPTER_STYLE_MAX_CHARS 字，服务端截断超长部分（规则层已经写死
        # "≤50 字"，但仍要在校验前兜底，不依赖模型自觉守约 — same defensive
        # hand as the deleted focus_traits truncate used to be). An
        # all-whitespace/empty result normalises to ``None`` rather than a
        # dangling empty string.
        if isinstance(result, dict) and isinstance(result.get("chapter_style"), str):
            result["chapter_style"] = result["chapter_style"].strip()[:CHAPTER_STYLE_MAX_CHARS] or None
        # 审后修复 🔵 (archive/REVIEW_REPORT_v1.4.0.md) — ``extra="allow"`` means
        # a model that ignores OPERATIONAL_RULES could still smuggle a dead
        # ``chapter_directive`` key back into a NEW chapter's structured_prompt
        # (old chapters keep the key from before this schema-deletion — that's
        # fine and expected; this pop is only about NOT letting a live LLM call
        # resurrect it). Pop it before validation so it never survives into the
        # persisted prompt, on ANY expand() call, model-compliant or not.
        if isinstance(result, dict):
            result.pop("chapter_directive", None)
        return StructuredPrompt.model_validate(result).model_dump(exclude_none=True)


def _expander_json_schema() -> dict[str, Any]:
    """JSON schema handed to ``complete_json``.

    Extends ``StructuredPrompt.model_json_schema()`` with explicit
    ``continuity_alerts`` / ``chapter_style`` slot descriptions so models that
    respect schema (OpenAI / Claude with structured outputs) see the exact
    same guardrails ``OPERATIONAL_RULES`` teaches in prose. v1.5.0 (NN) P1:
    the ``focus_traits`` and ``extra_notes`` slots are GONE — those two
    schema fields no longer exist on ``StructuredPrompt`` at all.
    """
    schema = StructuredPrompt.model_json_schema()
    properties = schema.setdefault("properties", {})
    # v1.4.0 (MM) P1 — continuity/contradiction notes FOR THE AUTHOR (never
    # read by the Writer — see ``writer._render_task_block``). v1.5.0 (NN)
    # P1 定案 #5: kept unchanged.
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
    # v1.5.0 (NN) P1 — new 领读员 output: ≤50 字 one-line chapter style note.
    # Three cages: ①服务端截断 CHAPTER_STYLE_MAX_CHARS 字 (see
    # PromptExpanderAgent.expand) ②规则层写死只谈句式/节奏/用词密度/叙事
    # 温度、禁情节性/意象性内容 (mirrored here so schema-aware models see the
    # same boundary) ③Step2 可编辑（作者否决权，前端）。
    properties["chapter_style"] = {
        "type": ["string", "null"],
        "maxLength": CHAPTER_STYLE_MAX_CHARS,
        "description": (
            "A ONE-LINE (<=50 Chinese characters) note on this chapter's "
            "style micro-adjustment. ONLY sentence length/rhythm, narrative "
            "pace, word density, or narrative temperature (warm/cold) — "
            "PURELY textual-craft properties. NEVER plot content, imagery, or "
            "any concrete scene detail. Bad: '写出他内心的挣扎与释然' (plot). "
            "Good: '短句为主，节奏偏快，用词克制冷静' (pure style). Leave "
            "null/empty when no special adjustment is needed this chapter."
        ),
    }
    return schema
