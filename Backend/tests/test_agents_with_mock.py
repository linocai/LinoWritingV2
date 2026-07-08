from __future__ import annotations

from tests.conftest import MockLLMClient
from app.agents.extractor import ExtractorAgent
from app.agents.prompt_expander import PromptExpanderAgent
from app.agents.writer import WriterAgent


def test_agents_use_mock_llm_contract():
    llm = MockLLMClient()
    context = {
        "all_characters": [{"id": "char-1", "name": "林夕", "role": "主角"}],
        "chapter": {"user_prompt": "找到线索"},
    }
    expanded = PromptExpanderAgent(llm).expand(context)
    assert expanded["plot_anchors"]
    assert expanded["characters_involved"] == ["char-1"]

    writer_context = {"structured_prompt": expanded, "characters": [], "timelines": {}, "recent_summaries": []}
    # v1.2.0 (HH) P7: WriterAgent.stream yields typed StreamChunk now — join
    # only the "token" chunks (mirrors chapters.py's produce_tokens, which
    # never lets "thinking" chunks into draft_text).
    text = "".join(chunk.text for chunk in WriterAgent(llm).stream(writer_context) if chunk.kind == "token")
    assert "铜钱" in text

    extractor_context = {
        "chapter": {"draft_text": text},
        "characters": [{"id": "char-1", "name": "林夕", "live_fields": {}}],
    }
    extracted = ExtractorAgent(llm).extract(extractor_context)
    assert extracted["timeline_events"][0]["character_id"] == "char-1"
