from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient
from app.schemas.structured_prompt import StructuredPrompt

# v0.7 §5.L.4 — Expander now infers 0-2 ``focus_traits`` per chapter so the
# Writer prompt has a concrete steering signal instead of treating every trait
# in every character card as equally important. Hard-cap at 2 because empirical
# testing shows 3+ traits push the Writer back into "checklist mode" — the
# exact failure we're trying to fix in §5.L.
MAX_FOCUS_TRAITS = 2


class PromptExpanderAgent:
    system_prompt = """
你是一个中文小说的剧情扩写助手。
根据用户的简短章节意图，扩写为结构化章节蓝图。
必须从 all_characters 里选择 characters_involved，且只使用角色 id。
must_happen / must_not_happen 必须具体、可验证。
风格参考 style_directive；如果为空，不要自行发明额外风格约束。

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

    def __init__(self, llm: LLMClient) -> None:
        self.llm = llm

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
    return schema
