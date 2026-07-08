"""v1.4.0 (MM) P2 — 两遍法修订引擎的调用封装 + 机制规则常量。

Background / why a separate module
----------------------------------
The two-pass method (PROJECT_PLAN.md §4 P2) leaves the *first* draft untouched
by the Writer's own streaming rules, then — only when the draft overshoots the
word-count ceiling — runs a **non-streaming** compression pass. That pass is a
distinct agent behaviour ("压缩删水，不重写") with its own mechanics, so its
rules live here in ``REVISION_OPERATIONAL_RULES`` rather than being bolted onto
``agents/writer.py`` (which P1 rewrote in parallel for a different concern).

Persona reuse, NOT persona coupling
-----------------------------------
The reviser is "the same novelist revising their own draft": same LLM Key
(``get_writer_llm_client`` / ``job.llm``) and the same **Writer persona**
(resolved at runtime via ``get_persona(db, "writer")`` and handed in). It does
NOT import anything from ``agents/writer.py`` — only the DB-editable persona
string flows in, composed with these code-level revision mechanics via the
shared ``personas.compose_system``. That keeps this module free of the P1 file
domain entirely.

Contract (locked by PROJECT_PLAN §4 P2 / 定案 #3):
  - non-streaming ``LLMClient.complete`` call, temperature 0.3,
    timeout = ``DEFAULT_NON_STREAM_TIMEOUT_SECONDS`` (300s);
  - input is deliberately SMALL — draft full text + the target [low, high]
    range + plot_anchors list + chapter style. NO character cards, NO world
    setting, NO summaries (those shaped the first draft; the reviser only
    compresses what's already there);
  - instruction = 压缩删水 / 锚点情节不得丢失 / 不加新情节 / 不改顺序;
  - ``harsher=True`` swaps in a stronger "第二轮更狠地压" rule variant for the
    single retry when the first pass still overshoots the retry ceiling.

v1.5.0 (NN) P1 — 优化师终极精简: input renamed/pruned to match the new
``StructuredPrompt`` shape — ``must_happen``→``plot_anchors`` (same list
shape, definition changed from "验收清单" to "领读注解"/锚点情节，措辞同步);
``must_not_happen`` deleted entirely (no replacement — the retired field had
no compensating rule anywhere in this pipeline); ``style_directive`` (the
retired global per-book channel) → ``chapter_style`` (the Expander's ≤50 字
per-chapter style note, read from ``structured_prompt`` — see
``services.write_jobs._compress_to_range``).
"""
from __future__ import annotations

from app.llm.base import LLMClient
from app.llm.openai_compatible import DEFAULT_NON_STREAM_TIMEOUT_SECONDS
from app.services.personas import DEFAULT_PERSONAS, compose_system

# Non-streaming call knobs (PROJECT_PLAN §4 定案 #3, locked).
REVISION_TEMPERATURE = 0.3
# =``DEFAULT_NON_STREAM_TIMEOUT_SECONDS`` (300s). Imported (not re-literaled) so
# the two stay in lockstep if that module constant is ever re-tuned.
REVISION_TIMEOUT_SECONDS = DEFAULT_NON_STREAM_TIMEOUT_SECONDS


REVISION_OPERATIONAL_RULES = """
你是同一位中文小说家，现在做的是**修订自己写好的初稿**——只压缩，不重写。

你唯一的任务：把「# 初稿全文」压缩到「# 目标字数区间」之内（字数按去掉所有空白字符计）。

铁律（逐条遵守）：
1. 删水，不删情节。删掉冗余的形容、重复的描写、拖沓的过渡、可有可无的枝节；
   但「# 锚点情节」里的每一条锚点情节都不得丢失——一件都不能少、不能弱化、不能一笔带过。
2. 不加新东西。不新增任何情节、人物、对话、设定、场景——初稿里没有的，压缩稿里也不能有。
   这是修订不是续写，更不是二次创作。
3. 不改顺序。事件推进的先后顺序与初稿保持一致，只在句子和段落层面删减、合并、收紧。
4. 文风与初稿保持一致（见「# 本章文风」；若该节缺失则保持初稿原有文风）；压缩后仍是连贯通顺的
   成稿正文，不是提纲、不是摘要、不是梗概。

只输出压缩后的正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()


HARSHER_REVISION_OPERATIONAL_RULES = """
你是同一位中文小说家，正在**第二轮压缩自己的稿子**——上一轮压得还不够狠，这一轮必须更狠。

你唯一的任务：把「# 初稿全文」（上一轮压缩后仍然超标的稿子）进一步大幅压缩，
落进「# 目标字数区间」之内（字数按去掉所有空白字符计）。

比上一轮更狠地删：合并重复或相似的场景、砍掉一切非必要的铺垫与心理描写、把长句改短、
把可省的对话和旁白删到只剩推动情节的部分、能一句话交代的绝不用一段。但——

铁律不变：
1. 「# 锚点情节」里的每一条锚点情节仍不得丢失，一件都不能少。宁可句子更短、段落更少，也不能丢锚点情节。
2. 不加任何新情节 / 人物 / 设定；不改事件顺序。
3. 压缩后仍是连贯的成稿正文，不是提纲、不是摘要。

只输出压缩后的正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()


class ReviserAgent:
    """Wraps a single non-streaming compression call over an existing draft.

    ``persona`` is the DB-resolved **Writer** persona (``get_persona(db,
    "writer")``); when ``None`` it falls back to the code-level Writer default
    so a bare ``ReviserAgent(llm)`` (tests / internal use) still runs with a
    sane persona rather than an empty one.
    """

    def __init__(self, llm: LLMClient, persona: str | None = None) -> None:
        self.llm = llm
        self._persona = persona if persona is not None else DEFAULT_PERSONAS["writer"]

    def revise(
        self,
        draft: str,
        *,
        word_low: int,
        word_high: int,
        plot_anchors: list[str],
        chapter_style: str,
        harsher: bool = False,
    ) -> str:
        """Return the compressed draft. Raises whatever ``LLMClient.complete``
        raises (LLMError / transport) — the worker degrades those to
        ``revision="unrevised"`` (never lets them abort the whole job)."""
        rules = HARSHER_REVISION_OPERATIONAL_RULES if harsher else REVISION_OPERATIONAL_RULES
        system = compose_system(self._persona, rules)
        user = self._render_user_message(
            draft,
            word_low=word_low,
            word_high=word_high,
            plot_anchors=plot_anchors,
            chapter_style=chapter_style,
        )
        return self.llm.complete(
            system=system,
            user=user,
            temperature=REVISION_TEMPERATURE,
            timeout=REVISION_TIMEOUT_SECONDS,
        )

    @staticmethod
    def _render_user_message(
        draft: str,
        *,
        word_low: int,
        word_high: int,
        plot_anchors: list[str],
        chapter_style: str,
    ) -> str:
        """Render the reviser's user message as a small sectioned document.

        Deliberately minimal (plan §4 P2): draft + range + plot_anchors +
        style. No cards / world / summaries — the reviser only compresses what's
        already on the page. Empty optional sections (header included) are
        omitted line-by-line so the model isn't handed empty scaffolding.

        v1.5.0 (NN) P1: ``must_not_happen``'s「# 不可出现」section is deleted
        entirely (no replacement); ``must_happen``→``plot_anchors`` (section
        renamed「# 必须保留的关键事件」→「# 锚点情节（不得丢失）」);
        ``style_directive``→``chapter_style`` (section renamed
        「# 文风要求」→「# 本章文风」).
        """
        sections: list[str] = [f"# 初稿全文（待压缩）\n{draft}"]
        sections.append(
            "# 目标字数区间\n"
            f"压缩后的正文须落在 {word_low}–{word_high} 字之间（按去掉所有空白字符计）。"
        )
        if plot_anchors:
            sections.append(
                "# 锚点情节（不得丢失）\n" + "\n".join(f"- {item}" for item in plot_anchors)
            )
        if chapter_style:
            sections.append(f"# 本章文风\n{chapter_style}")
        return "\n\n".join(sections)
