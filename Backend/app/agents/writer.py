from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

from app.llm.base import LLMClient


class WriterAgent:
    system_prompt = """
你是一个中文小说的写作执行者。
严格遵守 characters[*].frozen_fields，角色卡冻结区不能漂移。
必须写到 structured_prompt.must_happen 中的事件。
structured_prompt.must_not_happen 中的事件、元素和信息一字不提。
利用 timelines 保持角色连续性，尤其是角色知道什么、不知道什么、目标和状态。
风格遵循 style_directive。
目标字数 target_word_count，允许上下浮动 20%。
只输出正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()

    def __init__(self, llm: LLMClient) -> None:
        self.llm = llm

    def stream(self, context: dict[str, Any]) -> Iterator[str]:
        yield from self.llm.complete_stream(
            system=self.system_prompt,
            user=json.dumps(context, ensure_ascii=False, default=str),
            temperature=0.7,
            timeout=180,
        )
