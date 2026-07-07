from __future__ import annotations

from typing import Any

from app.agents.writer import WriterAgent


class _CapturingLLM:
    """Captures the user message Writer hands to the LLM client."""

    def __init__(self) -> None:
        self.last_user: str | None = None
        self.last_system: str | None = None

    def complete(self, **kwargs: Any) -> str:  # pragma: no cover - unused here
        return ""

    def complete_json(self, **kwargs: Any) -> dict[str, Any]:  # pragma: no cover - unused here
        return {}

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):
        self.last_system = system
        self.last_user = user
        if False:
            yield ""


def test_writer_prompt_contains_style_block_when_samples_present():
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进"},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
        "style_samples": [
            {"chapter_index": 7, "head": "雨夜山洞里。", "tail": "他离开了山洞。"},
        ],
    }
    # Consume the generator.
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "# 参考前文文风" in llm.last_user
    assert "第 7 章 · 片段（头）" in llm.last_user
    assert "雨夜山洞里。" in llm.last_user
    assert "第 7 章 · 片段（尾）" in llm.last_user
    assert "他离开了山洞。" in llm.last_user


def test_writer_prompt_omits_style_block_when_samples_empty():
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进"},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
        "style_samples": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "# 参考前文文风" not in llm.last_user


def test_writer_prompt_omits_style_block_when_key_missing():
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进"},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
        # No style_samples key at all.
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "# 参考前文文风" not in llm.last_user


def test_writer_prompt_short_sample_renders_only_head():
    """When tail is '' (short-chapter rule), only the head section appears."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进"},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
        "style_samples": [
            {"chapter_index": 3, "head": "极短的全文。", "tail": ""},
        ],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "第 3 章 · 片段（头）" in llm.last_user
    assert "极短的全文。" in llm.last_user
    assert "第 3 章 · 片段（尾）" not in llm.last_user


# ---- Phase L-2 (§5.L.5) — system_prompt rewrite assertions --------------

def test_writer_system_prompt_teaches_show_dont_tell_rules():
    """The new prompt's whole point is to fix the trait-checklist habit.

    Lock in the load-bearing instructional bits so a future "small tweak"
    can't quietly delete them.
    """
    sp = WriterAgent.system_prompt
    # Section headers from §5.L.5.
    assert "角色卡使用规则" in sp
    assert "本章重点" in sp
    assert "author_notes" in sp
    # Concept anchors that drive the model's framing.
    assert "幕后参考" in sp
    assert "focus_traits" in sp
    # Show-don't-tell example pair must survive intact (both halves).
    assert "❌ 反例" in sp
    assert "✓ 正例" in sp
    # The "water reservoir" metaphor is what makes the model OK with not
    # using every trait — keep it.
    assert "水库" in sp
    # Hard guardrail on author_notes — the only thing standing between
    # author's private notes and them being narrated verbatim.
    assert "绝不可有任何句子直接转述 author_notes" in sp


def test_writer_system_prompt_drops_old_strict_frozen_directive():
    """Regression: the v0.6 line that confused the model into thinking
    frozen_fields was a "must-display" checklist must be gone."""
    sp = WriterAgent.system_prompt
    assert "严格遵守 characters[*].frozen_fields" not in sp
    # The "冻结区不能漂移" wording in particular was misinterpreted by the
    # Writer as "every frozen field must appear on the page" — gone too.
    assert "冻结区不能漂移" not in sp


def test_writer_system_prompt_keeps_existing_plot_and_style_rules():
    """Don't regress the parts that were correct in v0.6 — must_happen /
    must_not_happen / timelines / target_word_count / output format."""
    sp = WriterAgent.system_prompt
    assert "must_happen" in sp
    assert "must_not_happen" in sp
    assert "timelines" in sp
    assert "style_directive" in sp
    assert "target_word_count" in sp
    assert "只输出正文纯文本" in sp


def test_writer_system_prompt_has_default_word_count_range_when_target_empty():
    """v1.3.1 (KK) P8: when target_word_count is empty/unset, the Writer must
    have a concrete default anchor (2500-3500 字) instead of the old bare
    "允许上下浮动 20%" wording (which had nothing to float around when
    target_word_count was itself empty). When a value IS provided, the ±20%
    rule still applies — locks both halves so a future edit can't silently
    drop the empty-case default."""
    sp = WriterAgent.system_prompt
    assert "2500" in sp and "3500" in sp
    assert "为空" in sp or "未提供" in sp
    assert "20%" in sp


def test_writer_system_prompt_describes_recent_fulltext_usage():
    """v1.3.1 (KK) P7 审后修复 🔵2 (reviewer 抓出): the Writer used to receive
    ``recent_fulltext`` (最近 3 章原文, ~1万字) with zero rule describing what
    it is or how to use it — the model could only guess from the key name.
    Locks a description matching the Expander side's continuity-grounding
    framing (see prompt_expander.py's OPERATIONAL_RULES), plus the red line
    (migrated from the now-effectively-dead style_samples paragraph — see
    context_pack.py's STYLE_SAMPLES_CHAPTER_COUNT docstring) that recent
    prose is for continuity/style reference only, never verbatim reuse."""
    sp = WriterAgent.system_prompt
    assert "recent_fulltext" in sp
    assert "连贯" in sp or "连续" in sp
    assert "不要照搬" in sp


def test_writer_user_message_carries_author_notes_when_present():
    """context_pack now includes characters[*].author_notes for Writer.

    This is a contract test: even though the Writer code itself doesn't
    inspect author_notes (it just JSON-dumps the context), we lock in that
    the field survives the user_message round-trip so a future refactor
    can't quietly strip it from the JSON.
    """
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进", "focus_traits": ["谨慎"]},
        "characters": [
            {
                "id": "c1",
                "name": "林夕",
                "frozen_fields": {"core_traits": "谨慎"},
                "live_fields": {},
                "author_notes": {"motivation": "为妹妹复仇"},
            }
        ],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "author_notes" in llm.last_user
    assert "为妹妹复仇" in llm.last_user
    assert "focus_traits" in llm.last_user
    assert "谨慎" in llm.last_user
