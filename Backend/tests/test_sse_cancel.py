"""Tests for the SSE producer cancel hook (§5.P.1 D).

These exercise three layers of the cancel chain:

1. ``OpenAICompatibleClient._stream`` honours a pre-set ``cancel_event``
   (unit, no real HTTP — we mock httpx.stream to feed canned SSE lines).
2. The producer thread in ``_write_stream`` stops enqueueing tokens once
   the consumer goes away, and the chapter status is restored to its
   previous state instead of stranding at ``writing``.
3. End-to-end: when a client closes the SSE response early, the daemon
   thread does NOT keep running indefinitely.

The cancel mechanism matters because without it every user-cancelled
write keeps the upstream LLM connection open, burning tokens (and money)
until the model naturally finishes.
"""
from __future__ import annotations

import threading
import time
from collections.abc import Iterator
from typing import Any
from unittest.mock import patch

from app.agents.writer import WriterAgent
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
        tokens = list(
            client.complete_stream(
                system="s",
                user="u",
                cancel_event=cancel,
            )
        )

    assert tokens == []  # No tokens consumed.
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
        for token in gen:
            yielded.append(token)
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
    ) -> Iterator[str]:
        for i in range(self.n_tokens):
            if cancel_event is not None and cancel_event.is_set():
                return
            self.considered.append(i)
            yield f"t{i}"
            time.sleep(self.per_token_sleep)


def test_writer_agent_forwards_cancel_event_to_llm():
    """WriterAgent.stream should plumb cancel_event into LLM.complete_stream."""
    llm = _ControlledStreamLLM(n_tokens=10, per_token_sleep=0.0)
    cancel = threading.Event()
    cancel.set()
    tokens = list(WriterAgent(llm).stream({}, cancel_event=cancel))
    assert tokens == []
    assert llm.considered == []  # Never even started the loop.


def test_write_stream_generator_finally_signals_cancel(db_session):
    """Closing the generator mid-stream must set the cancel event so the
    producer thread (and, transitively, the LLM client) stops.

    We can't rely on starlette/TestClient to faithfully simulate a
    client disconnect inside an in-process ASGI test — the response
    body is buffered and the generator runs to completion before
    iter_bytes ever sees a chunk. So we drive ``_write_stream``
    directly: yield a couple of events, then call ``.close()`` on the
    generator (this is exactly what FastAPI does when the underlying
    client disconnects). After the close, the producer must observe
    the cancel signal and exit.
    """
    from app.routers.chapters import _write_stream
    from app.models.book import Book
    from app.models.chapter import Chapter
    from app.models.character import Character

    book = Book(title="Cancel Gen", cover_color="#000000")
    db_session.add(book)
    db_session.flush()
    db_session.add(
        Character(
            book_id=book.id,
            name="测",
            role="主角",
            frozen_fields={"core_traits": "冷静"},
            live_fields={"current_status": "等待"},
        )
    )
    chapter = Chapter(
        book_id=book.id,
        index=1,
        title="第一章",
        user_prompt="短一点。",
        status="writing",
    )
    db_session.add(chapter)
    db_session.commit()
    db_session.refresh(chapter)

    slow_llm = _ControlledStreamLLM(n_tokens=30, per_token_sleep=0.03)
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
    )

    # Pull a few SSE chunks. We need at least the "started" event and
    # one "token" event to prove the stream is live.
    chunks: list[str] = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 3:
            break

    # Now simulate FastAPI's behaviour on client disconnect: close the
    # generator. This invokes the finally block, sets cancel_event,
    # and lets the producer thread bail out.
    gen.close()

    # Wait long enough for the producer to notice (each iteration
    # sleeps 30ms before re-checking cancel).
    time.sleep(0.4)

    db_session.refresh(chapter)
    # The finally block must restore the previous status.
    assert chapter.status == "prompt_ready"
    # And the LLM must have stopped well short of its 30-token budget.
    # Slack: a couple of tokens may already be in flight when cancel
    # fires; what matters is it didn't run to completion.
    assert len(slow_llm.considered) < 30


def test_producer_thread_exits_after_cancel(db_session):
    """The daemon thread must not outlive the cancelled stream.

    Drives ``_write_stream`` directly (same reason as the previous
    test: TestClient can't faithfully simulate an in-process
    disconnect). Counts non-main threads before and after, and
    asserts no new ones survived past the cancel.
    """
    from app.routers.chapters import _write_stream
    from app.models.book import Book
    from app.models.chapter import Chapter
    from app.models.character import Character

    book = Book(title="Thread Gen", cover_color="#000000")
    db_session.add(book)
    db_session.flush()
    db_session.add(
        Character(
            book_id=book.id,
            name="测2",
            role="主角",
            frozen_fields={"core_traits": "冷静"},
            live_fields={"current_status": "等待"},
        )
    )
    chapter = Chapter(
        book_id=book.id,
        index=1,
        title="第一章",
        user_prompt="短一点。",
        status="writing",
    )
    db_session.add(chapter)
    db_session.commit()
    db_session.refresh(chapter)

    threads_before = {t.ident for t in threading.enumerate()}

    slow_llm = _ControlledStreamLLM(n_tokens=50, per_token_sleep=0.05)
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
    )

    chunks = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 3:
            break
    gen.close()

    # Wait for the producer to notice cancel (sleeps 50ms per token
    # before checking) — 1s of slack is plenty.
    time.sleep(1.0)

    new_threads = [
        t
        for t in threading.enumerate()
        if t.ident not in threads_before and t.is_alive()
    ]
    leaked = [t for t in new_threads if t.daemon]
    assert not leaked, (
        f"Producer thread leaked after cancel: {[t.name for t in leaked]}"
    )
