"""Tests for the LLM-level SSE cancel chain (§5.P.1 D — mechanism reused by
v1.3.2 (LL) P1 writing-as-a-job, only the *trigger* moved to an explicit
``POST /write/cancel``).

These exercise the layers that stay identical after the P1 refactor:

1. ``OpenAICompatibleClient._stream`` honours a pre-set ``cancel_event``
   (unit, no real HTTP — we mock httpx.stream to feed canned SSE lines).
2. ``WriterAgent.stream`` plumbs ``cancel_event`` into the LLM client.

The cancel mechanism matters because without it a user-cancelled write keeps
the upstream LLM connection open, burning tokens (and money) until the model
naturally finishes. The *worker/registry* side (a cancel now goes through the
``WriteJob`` + ``POST /write/cancel``, and — critically — a client disconnect
NO LONGER cancels) is covered in ``test_write_jobs.py``.

``_FakeHttpxStream`` / ``_provider_key`` / ``_ControlledStreamLLM`` below are
shared helpers imported by ``test_stream_timeout.py`` / ``test_thinking_stream.py``
/ ``test_partial_draft_save.py`` — keep them here.
"""
from __future__ import annotations

import threading
import time
from collections.abc import Iterator
from typing import Any
from unittest.mock import patch

from app.agents.writer import WriterAgent
from app.llm.base import StreamChunk
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models.provider_key import ProviderKey
from tests.conftest import MockLLMClient


class _FakeHttpxStream:
    """Stand-in for the context manager returned by ``httpx.stream``.

    Yields SSE-style lines from ``lines`` via ``iter_lines``. Records
    whether the context manager was exited (which is what would close
    the upstream socket in production).
    """

    def __init__(self, lines: list[str]) -> None:
        self.lines = lines
        self.status_code = 200
        self.closed = False
        self._iter_started = False

    def __enter__(self) -> "_FakeHttpxStream":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.closed = True

    def iter_lines(self) -> Iterator[str]:
        self._iter_started = True
        for line in self.lines:
            yield line


def _provider_key() -> ProviderKey:
    return ProviderKey(
        id="00000000-0000-0000-0000-000000000001",
        key_label="test",
        provider_hint="custom",
        base_url="https://example.test/v1",
        api_key="sk-test-1234",
        model_name="test-model",
    )


def test_stream_breaks_immediately_when_cancel_event_set_before_iter():
    """If cancel is set before _stream even pulls a line, return at once."""
    client = OpenAICompatibleClient(_provider_key())
    cancel = threading.Event()
    cancel.set()  # Pre-cancelled.

    fake = _FakeHttpxStream(
        [
            'data: {"choices":[{"delta":{"content":"早"}}]}',
            'data: {"choices":[{"delta":{"content":"安"}}]}',
            "data: [DONE]",
        ]
    )

    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        chunks = list(
            client.complete_stream(
                system="s",
                user="u",
                cancel_event=cancel,
            )
        )

    assert chunks == []  # No tokens consumed.
    assert fake.closed  # Context manager exited → upstream socket closed.


def test_stream_breaks_mid_iteration_when_cancel_event_set_during():
    """Cancel mid-stream stops further token yields."""
    client = OpenAICompatibleClient(_provider_key())
    cancel = threading.Event()
    yielded: list[str] = []

    # 4 token lines + DONE. We'll cancel after token #2 is consumed.
    fake = _FakeHttpxStream(
        [
            'data: {"choices":[{"delta":{"content":"一"}}]}',
            'data: {"choices":[{"delta":{"content":"二"}}]}',
            'data: {"choices":[{"delta":{"content":"三"}}]}',
            'data: {"choices":[{"delta":{"content":"四"}}]}',
            "data: [DONE]",
        ]
    )

    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        gen = client.complete_stream(system="s", user="u", cancel_event=cancel)
        for chunk in gen:
            yielded.append(chunk.text)
            if len(yielded) == 2:
                cancel.set()
        # Generator must close naturally after seeing cancel.

    assert yielded == ["一", "二"]
    assert fake.closed


class _ControlledStreamLLM(MockLLMClient):
    """LLM mock that emits tokens slowly and respects ``cancel_event``.

    Each yield sleeps briefly so the test has a window to cancel. Records
    every token it considered yielding (whether or not it actually did)
    so we can assert the producer thread stopped early.
    """

    def __init__(self, n_tokens: int = 20, per_token_sleep: float = 0.02) -> None:
        self.n_tokens = n_tokens
        self.per_token_sleep = per_token_sleep
        self.considered: list[int] = []
        self.thread_alive_after_cancel = True

    def complete_stream(
        self,
        *,
        system: str,
        user: str,
        cancel_event: threading.Event | None = None,
        **kwargs: Any,
    ) -> Iterator[StreamChunk]:
        for i in range(self.n_tokens):
            if cancel_event is not None and cancel_event.is_set():
                return
            self.considered.append(i)
            yield StreamChunk(kind="token", text=f"t{i}")
            time.sleep(self.per_token_sleep)


def test_writer_agent_forwards_cancel_event_to_llm():
    """WriterAgent.stream should plumb cancel_event into LLM.complete_stream."""
    llm = _ControlledStreamLLM(n_tokens=10, per_token_sleep=0.0)
    cancel = threading.Event()
    cancel.set()
    tokens = list(WriterAgent(llm).stream({}, cancel_event=cancel))
    assert tokens == []
    assert llm.considered == []  # Never even started the loop.


# NOTE (v1.3.2 LL P1): the two pre-v1.3.2 tests here — closing the request
# generator *cancels* the producer, and the daemon thread exits on disconnect —
# encoded the exact behaviour this version deliberately REVERSES. A client
# disconnect no longer cancels the write; the worker runs on. The worker/
# registry/cancel semantics (including "disconnect does NOT set cancel_event")
# now live in ``test_write_jobs.py``.
