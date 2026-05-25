from __future__ import annotations

import json
from collections.abc import Iterator
from threading import Event
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
若 user 消息中附带「# 参考前文文风」段落，请学习这些原文片段的用词、句式、节奏；
不要照搬其中的情节、人物对白或具体场景，只汲取语言风格。
目标字数 target_word_count，允许上下浮动 20%。
只输出正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()

    def __init__(self, llm: LLMClient) -> None:
        self.llm = llm

    def stream(
        self,
        context: dict[str, Any],
        cancel_event: Event | None = None,
    ) -> Iterator[str]:
        yield from self.llm.complete_stream(
            system=self.system_prompt,
            user=self._render_user_message(context),
            temperature=0.7,
            timeout=180,
            cancel_event=cancel_event,
        )

    @staticmethod
    def _render_user_message(context: dict[str, Any]) -> str:
        """Serialise context as JSON, then append a markdown style-samples block.

        We keep the structured JSON intact (the model needs structured_prompt /
        characters / timelines as data), then append a human-readable section
        so the model can pattern-match prose against prose. When
        ``style_samples`` is missing or empty, no block is appended — empty
        story → no prior-style guidance.
        """
        samples = context.get("style_samples") or []
        json_blob = json.dumps(context, ensure_ascii=False, default=str)
        block = _render_style_samples_block(samples)
        if not block:
            return json_blob
        return f"{json_blob}\n\n{block}"


def _render_style_samples_block(samples: list[dict[str, Any]]) -> str:
    if not samples:
        return ""

    # Collect sample lines first; only emit the header if there is at least
    # one non-empty head/tail to show. Defends against the corner case where
    # every sample's head and tail are both empty strings (A-1 reviewer flag).
    body: list[str] = []
    for sample in samples:
        index = sample.get("chapter_index")
        head = sample.get("head") or ""
        tail = sample.get("tail") or ""
        if head:
            body.append(f"## 第 {index} 章 · 片段（头）：")
            body.append(head)
            body.append("")
        if tail:
            body.append(f"## 第 {index} 章 · 片段（尾）：")
            body.append(tail)
            body.append("")
    if not body:
        return ""

    lines: list[str] = [
        "# 参考前文文风",
        "以下是最近若干章节的原文片段，请学习这种文风（用词、句式、节奏）。"
        "**不要照搬情节**，只学风格。",
        "",
    ]
    lines.extend(body)
    return "\n".join(lines).rstrip()
