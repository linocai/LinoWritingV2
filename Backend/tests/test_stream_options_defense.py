"""v1.4.0 (MM) P2 (🟡8) — stream_options streaming-400 defence.

Contract (PROJECT_PLAN §4 P2): ``complete_stream`` always adds
``stream_options={"include_usage": True}`` (token观测). Some OpenAI-compatible
relays reject that field with a 400 BEFORE streaming any chunk. Since a 400
fires before any yield, ``_stream`` retries ONCE with the field stripped
(safe/idempotent), logging the first sanitised body. A second failure of any
kind raises that second error. A 400 whose payload never carried
stream_options is NOT retried.
"""
from __future__ import annotations

import pytest
from unittest.mock import patch

from app.llm.errors import LLMError
from app.llm.openai_compatible import OpenAICompatibleClient
from tests.test_sse_cancel import _FakeHttpxStream, _provider_key


class _Fake400Response:
    """A ``httpx.stream``-shaped context manager returning a 400 with a body."""

    def __init__(self, body: str) -> None:
        self._body = body
        self.status_code = 400
        self.closed = False

    def __enter__(self) -> "_Fake400Response":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.closed = True

    def read(self) -> bytes:
        return self._body.encode("utf-8")


def test_stream_400_with_stream_options_retries_without_it() -> None:
    client = OpenAICompatibleClient(_provider_key())
    fake400 = _Fake400Response('{"error":"unknown field: stream_options"}')
    fake200 = _FakeHttpxStream(['data: {"choices":[{"delta":{"content":"正文"}}]}', "data: [DONE]"])
    calls: list[dict] = []

    def _stream(method, url, *, headers, json, timeout):
        calls.append(dict(json))
        return fake400 if len(calls) == 1 else fake200

    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_stream):
        chunks = list(client.complete_stream(system="s", user="u"))

    assert [c.text for c in chunks] == ["正文"]
    assert len(calls) == 2
    assert "stream_options" in calls[0]  # first attempt carried it
    assert "stream_options" not in calls[1]  # retry stripped it
    assert fake400.closed  # the failed response was closed before retry


def test_stream_400_twice_raises_the_second_error() -> None:
    client = OpenAICompatibleClient(_provider_key())
    fake400a = _Fake400Response('{"error":"first: stream_options"}')
    fake400b = _Fake400Response('{"error":"second: model_not_found"}')
    calls: list[dict] = []

    def _stream(method, url, *, headers, json, timeout):
        calls.append(dict(json))
        return fake400a if len(calls) == 1 else fake400b

    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_stream):
        with pytest.raises(LLMError) as excinfo:
            list(client.complete_stream(system="s", user="u"))

    assert len(calls) == 2  # exactly one retry
    assert "second: model_not_found" in str(excinfo.value)  # the SECOND error surfaces


def test_stream_400_without_stream_options_key_is_not_retried() -> None:
    client = OpenAICompatibleClient(_provider_key())
    fake400 = _Fake400Response('{"error":"bad request"}')
    calls: list[dict] = []

    def _stream(method, url, *, headers, json, timeout):
        calls.append(dict(json))
        return fake400

    # Drive _stream directly with a payload that never had stream_options.
    payload = {"model": "m", "messages": [], "stream": True}
    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_stream):
        with pytest.raises(LLMError):
            list(client._stream(payload, timeout=1))

    assert len(calls) == 1  # no retry for a non-stream_options 400
