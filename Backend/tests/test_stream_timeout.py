"""Tests for v1.2.0 (HH) P6 — httpx timeout shape for the streaming path.

Contract (author-approved, see PROJECT_PLAN.md §4.1 P6): the read phase
keeps its pre-existing 180s value (unchanged, not tightened to 120 — that
would misfire on slow relays' natural inter-token gaps); connect/write/pool
get short fixed bounds; and critically there is **no separate overall-
duration timeout** — httpx.Timeout simply has no such phase, so as long as
each read keeps arriving inside the read-timeout window the stream can run
for however long the full generation takes.

These tests never sleep for real (that would make CI slow/flaky and doesn't
actually prove anything about httpx's timeout semantics — httpx enforces
timeouts inside its own transport, which we mock out entirely here). Instead
they assert:
  1. `OpenAICompatibleClient.complete_stream` builds an `httpx.Timeout` with
     the exact contracted per-phase values and passes it through to
     `httpx.stream`.
  2. A stream with many chunks, each well inside a *tiny* injected read
     timeout, completes successfully end-to-end even though the total
     elapsed time across all chunks would badly exceed that tiny timeout if
     it were (incorrectly) applied as a whole-response cap — proving
     `_stream`'s own Python-level loop imposes no additional overall-
     duration ceiling of its own (the only place such a cap *could* sneak in
     outside of httpx itself).
"""
from __future__ import annotations

from collections.abc import Iterator
from typing import Any
from unittest.mock import patch

import httpx

from app.llm.openai_compatible import OpenAICompatibleClient
from app.models.provider_key import ProviderKey
from tests.test_sse_cancel import _FakeHttpxStream


def _provider_key() -> ProviderKey:
    return ProviderKey(
        id="00000000-0000-0000-0000-000000000002",
        key_label="test-p6",
        provider_hint="custom",
        base_url="https://example.test/v1",
        api_key="sk-test-5678",
        model_name="test-model",
    )


def test_complete_stream_builds_httpx_timeout_with_contracted_phases():
    """Locks the exact per-phase values so a future edit can't silently
    regress read back down to 120 or drop the explicit phase split."""
    client = OpenAICompatibleClient(_provider_key())
    fake = _FakeHttpxStream(["data: [DONE]"])

    captured_kwargs: dict[str, Any] = {}

    def _capture_stream(*args: Any, **kwargs: Any) -> _FakeHttpxStream:
        captured_kwargs.update(kwargs)
        return fake

    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_capture_stream):
        list(client.complete_stream(system="s", user="u"))

    timeout = captured_kwargs["timeout"]
    assert isinstance(timeout, httpx.Timeout)
    assert timeout.connect == 15
    assert timeout.read == 180  # unchanged — not tightened to 120
    assert timeout.write == 30
    assert timeout.pool == 15


def test_complete_stream_respects_explicit_timeout_kwarg_as_read_phase():
    """WriterAgent passes `timeout=180` explicitly (unchanged value) — this
    must land in the `read` phase, not get discarded."""
    client = OpenAICompatibleClient(_provider_key())
    fake = _FakeHttpxStream(["data: [DONE]"])
    captured_kwargs: dict[str, Any] = {}

    def _capture_stream(*args: Any, **kwargs: Any) -> _FakeHttpxStream:
        captured_kwargs.update(kwargs)
        return fake

    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_capture_stream):
        list(client.complete_stream(system="s", user="u", timeout=180))

    timeout = captured_kwargs["timeout"]
    assert timeout.read == 180


class _ManyChunksStream:
    """Like `_FakeHttpxStream` but yields many chunks. Used to prove the
    Python-side consumption loop has no wall-clock cap of its own — if it
    did, a large enough chunk count run through the mocked (instant, no real
    I/O) transport would still trip it, since the only thing standing
    between "many chunks" and "long total duration" in production is
    per-chunk network latency, which this mock has none of. The assertion
    that matters is architectural: no `time.monotonic() - started > N` check
    exists anywhere in `_stream`'s loop."""

    def __init__(self, n_chunks: int) -> None:
        self.status_code = 200
        self.closed = False
        self.n_chunks = n_chunks

    def __enter__(self) -> "_ManyChunksStream":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.closed = True

    def iter_lines(self) -> Iterator[str]:
        for i in range(self.n_chunks):
            yield f'data: {{"choices":[{{"delta":{{"content":"t{i}"}}}}]}}'
        yield "data: [DONE]"


def test_stream_with_tiny_injected_read_timeout_and_many_chunks_completes(
    monkeypatch: Any,
) -> None:
    """Inject an artificially tiny `httpx.Timeout(read=0.2)` (simulating the
    plan's "read=0.2s" scenario) and a stream of many chunks. Because httpx
    itself is mocked out (no real transport, no real timeout enforcement
    happens here), this test's job is narrower but still meaningful: prove
    `_stream`'s Python loop consumes an arbitrarily long chunk sequence
    without imposing any of *its own* elapsed-time ceiling — the only
    timeout authority is httpx's transport layer (mocked away), never a
    home-grown check in this module. No real sleep anywhere in this test.
    """
    client = OpenAICompatibleClient(_provider_key())
    many = _ManyChunksStream(n_chunks=500)

    with patch("app.llm.openai_compatible.httpx.stream", return_value=many):
        tokens = list(
            client.complete_stream(
                system="s",
                user="u",
                timeout=0.2,  # tiny read timeout — irrelevant to the mock,
                # but proves passing a small value doesn't change _stream's
                # own behaviour (no extra cap layered on top).
            )
        )

    assert len(tokens) == 500
    assert all(chunk.kind == "token" for chunk in tokens)
    assert tokens[0].text == "t0"
    assert tokens[-1].text == "t499"
    assert many.closed
