from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient
from app.schemas.structured_prompt import StructuredPrompt


class PromptExpanderAgent:
    system_prompt = """
你是一个中文小说的剧情扩写助手。
根据用户的简短章节意图，扩写为结构化章节蓝图。
必须从 all_characters 里选择 characters_involved，且只使用角色 id。
must_happen / must_not_happen 必须具体、可验证。
风格参考 style_directive；如果为空，不要自行发明额外风格约束。
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
            schema=StructuredPrompt.model_json_schema(),
            temperature=0.4,
        )
        prompt = StructuredPrompt.model_validate(result).model_dump(exclude_none=True)
        if not (prompt.get("chapter_goal") or "").strip():
            raise ValueError("Expander output missing non-empty chapter_goal")
        return prompt
