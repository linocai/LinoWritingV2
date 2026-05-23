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
