"""Tests for v1.3.1 (KK) P3 — non-streaming default request timeout.

Contract (PROJECT_PLAN.md §4 P3): `OpenAICompatibleClient.complete` /
`complete_json` used to default their `timeout` kwarg to 60s via
`kwargs.get("timeout", 60)`. Thinking-capable upstream models can take
longer than that on extract/expand/finalize/import/parse, so the default
is raised to 300s. Callers (all agents) never pass an explicit `timeout`
kwarg today, so this single default change covers every non-streaming call
site. The streaming path (`complete_stream`, read=180 via its own
`httpx.Timeout`) is untouched — see test_stream_timeout.py.
"""
from __future__ import annotations

from typing import Any
from unittest.mock import patch

from app.llm.openai_compatible import (
    DEFAULT_NON_STREAM_TIMEOUT_SECONDS,
    OpenAICompatibleClient,
)
from app.models.provider_key import ProviderKey


def _provider_key() -> ProviderKey:
    return ProviderKey(
        id="00000000-0000-0000-0000-000000000003",
        key_label="test-p3",
        provider_hint="custom",
        base_url="https://example.test/v1",
        api_key="sk-test-p3",
        model_name="test-model",
    )


class _FakeResponse:
    status_code = 200

    @staticmethod
    def json() -> dict[str, Any]:
        return {"choices": [{"message": {"content": "ok"}}]}


def test_default_non_stream_timeout_constant_is_300() -> None:
    """Locks the contracted value so a future edit can't silently drift it."""
    assert DEFAULT_NON_STREAM_TIMEOUT_SECONDS == 300


def test_complete_uses_300s_default_timeout_when_caller_passes_none() -> None:
    client = OpenAICompatibleClient(_provider_key())
    captured: dict[str, Any] = {}

    def _capture_post(*args: Any, **kwargs: Any) -> _FakeResponse:
        captured.update(kwargs)
        return _FakeResponse()

    with patch("app.llm.openai_compatible.httpx.post", side_effect=_capture_post):
        result = client.complete(system="s", user="u")

    assert result == "ok"
    assert captured["timeout"] == 300


def test_complete_json_uses_300s_default_timeout_when_caller_passes_none() -> None:
    client = OpenAICompatibleClient(_provider_key())
    captured: dict[str, Any] = {}

    class _JsonResponse:
        status_code = 200

        @staticmethod
        def json() -> dict[str, Any]:
            return {"choices": [{"message": {"content": '{"a": 1}'}}]}

    def _capture_post(*args: Any, **kwargs: Any) -> _JsonResponse:
        captured.update(kwargs)
        return _JsonResponse()

    with patch("app.llm.openai_compatible.httpx.post", side_effect=_capture_post):
        result = client.complete_json(system="s", user="u", schema={})

    assert result == {"a": 1}
    assert captured["timeout"] == 300


def test_complete_respects_explicit_timeout_kwarg_override() -> None:
    """An explicit `timeout` kwarg (none of today's callers pass one, but the
    plumbing must still honor it) is not clobbered by the new default."""
    client = OpenAICompatibleClient(_provider_key())
    captured: dict[str, Any] = {}

    def _capture_post(*args: Any, **kwargs: Any) -> _FakeResponse:
        captured.update(kwargs)
        return _FakeResponse()

    with patch("app.llm.openai_compatible.httpx.post", side_effect=_capture_post):
        client.complete(system="s", user="u", timeout=45)

    assert captured["timeout"] == 45
