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

# v1.0.0 EE Phase 2 (§4.1 / §5.3) — the Expander also emits a 200-300 字
# ``chapter_directive``, the just-in-time "本章创作指令" the author审 before the
# Writer runs. P1 红线: the directive is STEERING (direction / tension / what
# this chapter must achieve), never KNOWLEDGE — character-card / timeline
# content reaches the Writer on a separate Context-Pack line. The boundary is
# enforced twice: once in the (DB) persona's [边界] 段 and once in the schema /
# operational-rules wording below.
CHAPTER_DIRECTIVE_MIN_CHARS = 200
CHAPTER_DIRECTIVE_MAX_CHARS = 300


class PromptExpanderAgent:
    # Fixed expansion mechanics. The persona ([人格]/[原则]/[边界], DB-stored &
    # App-editable) is resolved by ``get_persona(db, 'expander')`` at the router
    # and composed in front of these rules at runtime (see ``compose_system``).
    #
    # v1.3.0 (II/JJ) P4 — 去大纲化: the whole-book ``outline`` input is gone
    # (book_outlines table deleted in P5). The Expander's job is redefined to
    # three things only: ①结构化 ②核连续性 ③蒸馏指令. It never invents plot
    # the author didn't write — it structures / checks / distills what's
    # already there in ``chapter.user_prompt`` (now a full narrative paragraph,
    # not a one-liner) and ``recent_summaries`` (已完成章梗概).
    OPERATIONAL_RULES = """
你是一个中文小说的剧情扩写助手。
just-in-time 读「三类输入」现切本章：① 你的人格（system 前段）；
② 相关记忆切片 —— involved_characters（在场角色卡 + 近期时间线）与两层记忆：
   recent_fulltext（最近 3 章已完成章节的原文全文，用于精细连续性核对）+
   recent_summaries（更早所有已完成章节的梗概，动态，由档案员每章回写）；
   ③ chapter.user_prompt —— 作者写的本章剧情完整叙述（一段话，描述这一章要
   发生的事）。

你只做三件事：
1. **结构化**：把作者的本章叙述整理成结构化章节蓝图。只填 chapter_goal /
   must_happen / must_not_happen / characters_involved / scene_setting /
   narrative_pov / target_word_count / extra_notes / focus_traits /
   chapter_directive 这些既有字段，**不要发明任何新字段**。
2. **核连续性**：对照 recent_fulltext（最近 3 章原文）与 recent_summaries
   （更早章节梗概），核对本章叙述与前文是否接得上；如果发现接不上，在
   chapter_directive 里提示作者，不要擅自改动情节。**recent_fulltext 与
   recent_summaries 都为空时**（第一章，或还没有前文）跳过连续性核对，只做
   结构化 + 蒸馏。
3. **蒸馏指令**：把作者的本章叙述蒸馏成 200–300 字的 chapter_directive。

红线：**不发明任何作者没写的情节**——你只结构化、核对、蒸馏作者已经写下的
内容，绝不新增剧情。

必须从 all_characters 里选择 characters_involved，且只使用角色 id。
must_happen / must_not_happen 必须具体、可验证，且来自作者的本章叙述。
风格参考 style_directive；如果为空，不要自行发明额外风格约束。

# focus_traits（本章重点 emerge 的角色特质）
从 characters_involved 涉及角色的 frozen_fields / author_notes 池里，
挑 0-2 个本章最相关的 trait 放进 focus_traits。
- 内容是"trait 名"的纯字符串（如 "谨慎"、"对妹妹的愧疚"），
  不是字段路径（不要写成 "core_traits.谨慎"）。
- 不要挑超过 2 个 — 让 Writer 聚焦。
- 如果本章场景不需要任何 trait 重点（纯过场 / 纯动作场），返回空数组。
- 选择标准：哪些特质在本章的抉择/冲突里会真正驱动角色行为。

# chapter_directive（本章创作指令，200–300 字纯文本）
给 Writer 的「方向盘」：写本章要达成什么、张力在哪、承接什么落点、
注意哪条还开着的伏笔。这是 steering，不是知识搬运：
- **绝不**把人物卡（frozen_fields / live_fields / author_notes）或时间线的内容
  抄进 directive —— 角色知识由 Context Pack 另一条线直达 Writer。
- 不写字段名（如 core_traits / author_notes / live_fields），不转述 author_notes 片段。
- 贴着作者的本章叙述走，不发明作者没写的情节。
- 长度控制在 200–300 字。

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
        prompt = StructuredPrompt.model_validate(result).model_dump(exclude_none=True)
        if not (prompt.get("chapter_goal") or "").strip():
            raise ValueError("Expander output missing non-empty chapter_goal")
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
    # v1.0.0 EE Phase 2 (§5.3) — the 200-300 字 steering directive. The
    # description doubles as a model-facing P1 guardrail: it is direction,
    # never copied character-card / timeline content.
    properties["chapter_directive"] = {
        "type": ["string", "null"],
        "description": (
            "本章创作指令 (200-300 Chinese chars). STEERING only — what this "
            "chapter must achieve, where the tension is, which落点 it picks up, "
            "which open伏笔 to mind. NEVER copy character-card (frozen_fields / "
            "live_fields / author_notes) or timeline content into it; that "
            "knowledge reaches the Writer on a separate line. No field names."
        ),
    }
    return schema
