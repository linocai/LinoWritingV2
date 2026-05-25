"""Phase L-2 (§5.L.4) — Expander infers ``focus_traits`` 0-2 strings.

Covers:
- Expander parses a non-empty focus_traits list into StructuredPrompt.
- Expander parses an empty focus_traits list (chapter has no trait emphasis).
- Expander truncates server-side when the LLM over-delivers (>2).
- Expander tolerates focus_traits missing entirely (back-compat with v0.6
  models that haven't learned the new schema slot).
- The JSON schema handed to ``complete_json`` actually exposes the slot.
"""
from __future__ import annotations

from collections.abc import Iterator
from typing import Any

from app.agents.prompt_expander import MAX_FOCUS_TRAITS, PromptExpanderAgent, _expander_json_schema


class _ScriptedLLM:
    """Mock LLM that returns a canned JSON dict for ``complete_json``."""

    def __init__(self, payload: dict[str, Any]) -> None:
        self._payload = payload
        self.last_schema: dict[str, Any] | None = None
        self.last_user: str | None = None

    def complete(self, **kwargs: Any) -> str:  # pragma: no cover - unused
        return ""

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        self.last_schema = schema
        self.last_user = user
        return dict(self._payload)

    def complete_stream(self, **kwargs: Any) -> Iterator[str]:  # pragma: no cover
        if False:
            yield ""


def _base_payload(**overrides: Any) -> dict[str, Any]:
    payload = {
        "chapter_goal": "推进剧情",
        "must_happen": ["主角进入山洞"],
        "must_not_happen": ["不揭秘"],
        "characters_involved": ["char-1"],
        "scene_setting": "雨夜",
        "narrative_pov": "third_person_limited",
        "target_word_count": 800,
    }
    payload.update(overrides)
    return payload


def test_expander_parses_focus_traits_when_present():
    llm = _ScriptedLLM(_base_payload(focus_traits=["谨慎", "对妹妹的愧疚"]))
    result = PromptExpanderAgent(llm).expand({"chapter": {"user_prompt": "找线索"}})
    assert result["focus_traits"] == ["谨慎", "对妹妹的愧疚"]


def test_expander_parses_empty_focus_traits():
    """Pure transition / action chapter — empty array is a valid signal."""
    llm = _ScriptedLLM(_base_payload(focus_traits=[]))
    result = PromptExpanderAgent(llm).expand({"chapter": {"user_prompt": "短打斗"}})
    # exclude_none drops None, but empty list is still emitted.
    assert result.get("focus_traits") == []


def test_expander_truncates_over_two_focus_traits():
    """LLM over-delivers — server-side truncate kicks in (§5.L.4)."""
    llm = _ScriptedLLM(_base_payload(focus_traits=["谨慎", "愧疚", "倔强", "孤僻"]))
    result = PromptExpanderAgent(llm).expand({"chapter": {"user_prompt": "x"}})
    assert len(result["focus_traits"]) == MAX_FOCUS_TRAITS == 2
    assert result["focus_traits"] == ["谨慎", "愧疚"]


def test_expander_drops_non_string_focus_traits():
    """Defensive: model emits ints / dicts mixed in — we keep only strings."""
    llm = _ScriptedLLM(_base_payload(focus_traits=["谨慎", 42, {"trait": "倔强"}]))
    result = PromptExpanderAgent(llm).expand({"chapter": {"user_prompt": "x"}})
    assert result["focus_traits"] == ["谨慎"]


def test_expander_tolerates_missing_focus_traits():
    """Old model / forgetful prompt — no focus_traits key at all.

    Pydantic's ``default_factory=list`` kicks in so we always have a list.
    """
    llm = _ScriptedLLM(_base_payload())
    result = PromptExpanderAgent(llm).expand({"chapter": {"user_prompt": "x"}})
    assert result.get("focus_traits") == []


def test_expander_json_schema_advertises_focus_traits():
    """Models with structured-output support read the schema — verify the
    slot is actually there with the right shape and maxItems cap."""
    schema = _expander_json_schema()
    focus = schema["properties"]["focus_traits"]
    assert focus["type"] == "array"
    assert focus["items"] == {"type": "string"}
    assert focus["maxItems"] == MAX_FOCUS_TRAITS


def test_expander_system_prompt_mentions_focus_traits_rules():
    """Keyword regression — the system_prompt must teach the model the rules,
    or the schema slot alone won't fix the narrative bug §5.L is about."""
    sp = PromptExpanderAgent.system_prompt
    assert "focus_traits" in sp
    assert "0-2" in sp
    assert "author_notes" in sp
