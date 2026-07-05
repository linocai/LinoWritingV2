from __future__ import annotations

import json
from collections.abc import Iterator
from threading import Event
from typing import Any

from app.llm.base import LLMClient, StreamChunk
from app.services.personas import DEFAULT_PERSONAS, compose_system

# v1.0.0 EE Phase 2 (archive/v1.0.0_plan.md §4.2 / §4.4) — the runtime system
# prompt is composed from two layers:
#   1. the *persona* (voice + boundary), DB-stored & App-editable, resolved by
#      ``get_persona(db, 'writer')`` at the router and passed into the
#      constructor — when absent it falls back to ``DEFAULT_PERSONAS['writer']``;
#   2. ``OPERATIONAL_RULES`` below — the fixed §5.L mechanics (card-usage rules,
#      focus_traits handling, author_notes guardrail, plot/style/output format).
#      These are agent *behaviour*, not persona, so they stay in code.
# The two are joined as ``persona + "\n\n" + OPERATIONAL_RULES`` (see
# ``compose_system``). The class attribute ``system_prompt`` keeps exposing the
# default-composed prompt for keyword-regression tests.


class WriterAgent:
    OPERATIONAL_RULES = """
你是一个中文小说的写作执行者。

# 本章方向（chapter_directive）
chapter_directive 是优化师给你的「本章创作指令」(200–300 字)——本章的**方向盘**：
本章要达成什么、张力在哪、承接什么落点、注意哪条还开着的伏笔。
**严格按它执行**，不越权推进 directive 之外的剧情。
它只给方向，**不给知识**——角色是谁、知道什么、当前状态，全在 characters / timelines 里
（另一条线，见下）；directive 与角色卡是**分开的两条线**，不要把 directive 当角色资料。
若本章没有 chapter_directive（字段缺失或为 null），就退回按 structured_prompt 蓝图写，
不要因为缺少 directive 而停笔或编一个方向出来。

# 角色卡使用规则（读懂这条比读对人设更重要）

characters[*] 的 frozen_fields 和 author_notes 是**幕后参考** —
用来帮你判断角色在情境中如何行动/说话/选择，**不是清单也不是检查表**。

绝不要为了"证明你看了角色卡"而把人格直接说出来：
- ❌ 反例："林夕谨慎地观察了四周" / "刀子嘴豆腐心的他叹了口气"
- ✓ 正例："林夕在原地站了三息，目光从左到右扫过。" /
        "他骂了一句脏话，声音很轻。然后把自己的水袋递了过去。"

同一项 trait 在整章里**最多用一次**作为行动驱动，不要反复 narrate。
不要把字段名（如 "core_traits"、"background"）或字段内容**逐字搬到正文**。
角色卡是水库，不是必须排空的水桶 — 不自然的 trait 就完全不用。

# 本章重点
structured_prompt.focus_traits 是本章**可重点 emerge** 的 0-2 个特质，
其它 trait 保持隐性，不主动展示。**为空时不要刻意 emerge 任何特质** —
按 plot 自然行进即可，不要为了凑满"重点"而编一个出来。

# author_notes 处理
author_notes 是角色的"演员小抄"：动机/过往/秘密。这是**纯幕后**，
正文里**绝不可有任何句子直接转述 author_notes 的内容**。它的作用
只是让你判断角色在抉择关口会怎么走 — 决定后，只写抉择和行动。

# 情节与风格约束
必须写到 structured_prompt.must_happen 中的事件。
structured_prompt.must_not_happen 中的事件、元素和信息一字不提。
利用 timelines 保持角色连续性，尤其是角色知道什么、不知道什么、目标和状态。
风格遵循 style_directive。
若 user 消息中附带「# 参考前文文风」段落，请学习这些原文片段的用词、句式、节奏；
不要照搬其中的情节、人物对白或具体场景，只汲取语言风格。
目标字数 target_word_count，允许上下浮动 20%。
只输出正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()

    # Backward-compat / regression surface: the default-composed system prompt.
    system_prompt = compose_system(DEFAULT_PERSONAS["writer"], OPERATIONAL_RULES)

    def __init__(self, llm: LLMClient, persona: str | None = None) -> None:
        self.llm = llm
        # Persona resolved from DB at the router (``get_persona``); fall back to
        # the code-level default so bare ``WriterAgent(llm)`` callers (tests,
        # internal use) never run with an empty persona.
        self.system_prompt = compose_system(
            persona if persona is not None else DEFAULT_PERSONAS["writer"],
            self.OPERATIONAL_RULES,
        )

    def stream(
        self,
        context: dict[str, Any],
        cancel_event: Event | None = None,
    ) -> Iterator[StreamChunk]:
        # v1.2.0 (HH) P7: pure pass-through — `complete_stream` now yields
        # typed StreamChunk (token/thinking) instead of bare str; this
        # method transparently forwards whatever the LLM client yields.
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
