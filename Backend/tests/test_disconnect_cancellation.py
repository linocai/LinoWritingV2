"""Tests for v1.2.0 (HH) P8 — prompt disconnect cancellation.

Background (see PROJECT_PLAN.md P8 for the full repro): Starlette's
``StreamingResponse`` drives a *sync* generator body (``_write_stream``) via
``starlette.concurrency.iterate_in_threadpool``, which calls
``anyio.to_thread.run_sync(next, gen)`` with the library default
``abandon_on_cancel=False`` — i.e. the await is wrapped in a *shielded*
cancel scope. Locally reproducing a real client disconnect against a real
uvicorn server (raw socket abort, not the in-process ``TestClient`` which
can't simulate this — see ``test_sse_cancel.py``'s docstrings) showed the
disconnected stream's cleanup (``finally`` block: partial-draft save,
``cancel_event.set()`` that stops the daemon LLM producer thread) never
ran at all within the observation window (minutes), not the ~140s
originally suspected: cancellation of the ASGI request task is shielded
from the blocked worker thread, and even once the request task itself is
torn down, nothing calls ``.close()`` on the abandoned generator.

The fix, ``chapters._iterate_sync_stream_cancellable``, replaces
Starlette's default threadpool driver for this one route with one that:

  1. Uses ``abandon_on_cancel=True`` so a cancelled awaiting task doesn't
     shield the blocked thread call — cancellation is delivered promptly.
  2. Sets ``disconnect_event`` (thread-safe) immediately on cancellation.
  3. Explicitly (and *safely* — retrying past the expected transient
     ``ValueError: generator already executing``) calls ``.close()`` on
     the sync generator, which throws ``GeneratorExit`` into it — the
     same thing that happens on today's already-tested "happy path"
     teardown, just promptly instead of never.

These tests exercise the new wrapper directly with ``anyio.run`` (no new
test dependency needed — ``anyio`` is already a transitive dependency of
FastAPI/Starlette, and is now imported directly by ``chapters.py``).
``_write_stream`` itself is unmodified in shape and already covered by
``test_sse_cancel.py`` / ``test_partial_draft_save.py``'s direct
generator-driving tests; the ``disconnect_event`` parameter added to its
signature is optional and defaults to a private, never-set ``Event()``,
so those existing tests are unaffected (checked here too, defensively).
"""
from __future__ import annotations

import threading
import time
from collections.abc import Iterator
from typing import Any

import anyio
import pytest

from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.routers.chapters import _iterate_sync_stream_cancellable, _write_stream
from tests.conftest import MockLLMClient


class _SlowLLM(MockLLMClient):
    """Emits ``n_tokens`` tokens, ``per_token_sleep`` apart, honouring
    ``cancel_event`` — same shape as ``test_sse_cancel._ControlledStreamLLM``.
    """

    def __init__(self, n_tokens: int = 20, per_token_sleep: float = 0.05) -> None:
        self.n_tokens = n_tokens
        self.per_token_sleep = per_token_sleep
        self.considered: list[int] = []

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


def _make_chapter(db_session, *, status: str, draft_text: str | None = None) -> Chapter:
    book = Book(title="P8 Disconnect", cover_color="#123456")
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
        status=status,
        draft_text=draft_text,
    )
    db_session.add(chapter)
    db_session.commit()
    db_session.refresh(chapter)
    return chapter


def test_wrapper_closes_generator_promptly_on_cancellation(db_session):
    """The core P8 fix: cancelling the *consuming* task must reach
    ``_write_stream``'s ``finally`` — proven here by driving the real
    async wrapper via ``anyio``'s own cancel-scope mechanism (the same
    one Starlette's ``StreamingResponse.__call__`` uses on real client
    disconnect), not just calling ``.close()`` directly (that path was
    already covered before P8 and never hung).
    """
    chapter = _make_chapter(db_session, status="writing")
    slow_llm = _SlowLLM(n_tokens=30, per_token_sleep=0.05)
    disconnect_event = threading.Event()
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
        writer_persona="测试 Writer 人格",
        disconnect_event=disconnect_event,
    )

    result: dict[str, Any] = {"finally_ran": False, "items": []}

    async def consume_then_cancel():
        wrapped = _iterate_sync_stream_cancellable(gen, disconnect_event, chapter.id)
        async with anyio.create_task_group() as tg:

            async def drive():
                async for item in wrapped:
                    result["items"].append(item)
                    if len(result["items"]) >= 2:
                        tg.cancel_scope.cancel()

            tg.start_soon(drive)

    started = time.monotonic()
    anyio.run(consume_then_cancel)
    elapsed = time.monotonic() - started

    # disconnect_event must have been set by the wrapper's finally.
    assert disconnect_event.is_set()
    # Cleanup must complete quickly — bounded by a couple of
    # per_token_sleep cycles (0.05s each), nowhere near open-ended.
    assert elapsed < 5.0, f"cancellation cleanup took {elapsed:.2f}s — should be seconds, not unbounded"

    db_session.refresh(chapter)
    # previous_status="prompt_ready" + non-empty parts → P5 conservative
    # policy unconditionally saves the partial draft.
    assert chapter.status == "draft_ready"
    assert chapter.draft_text  # non-empty partial draft was saved
    assert len(result["items"]) >= 2


def test_wrapper_stops_producer_thread_after_cancellation(db_session):
    """End-to-end proof that disconnect cancellation actually reaches the
    daemon producer thread (and, transitively, would close the upstream
    LLM socket) — not just that the SSE frame stream stops.
    """
    chapter = _make_chapter(db_session, status="writing")
    slow_llm = _SlowLLM(n_tokens=50, per_token_sleep=0.03)
    disconnect_event = threading.Event()
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
        writer_persona="测试 Writer 人格",
        disconnect_event=disconnect_event,
    )

    async def consume_then_cancel():
        wrapped = _iterate_sync_stream_cancellable(gen, disconnect_event, chapter.id)
        async with anyio.create_task_group() as tg:

            async def drive():
                count = 0
                async for _item in wrapped:
                    count += 1
                    if count >= 3:
                        tg.cancel_scope.cancel()

            tg.start_soon(drive)

    anyio.run(consume_then_cancel)

    # Give the daemon thread a moment to notice cancel_event (it checks
    # once per token, per_token_sleep=0.03s apart) — generous slack.
    time.sleep(0.5)
    considered_at_cancel = len(slow_llm.considered)
    time.sleep(0.5)
    # If the producer were still running, more tokens would have been
    # "considered" during this second window. It must not be.
    assert len(slow_llm.considered) == considered_at_cancel, (
        "producer thread kept generating tokens after client disconnect — "
        "this is exactly the billable-token leak P8 fixes"
    )
    assert len(slow_llm.considered) < 50


def test_wrapper_normal_completion_unaffected(db_session):
    """Sanity: when the stream finishes normally (no cancellation), the
    wrapper must behave exactly like Starlette's own
    ``iterate_in_threadpool`` — forward every SSE frame, then stop
    cleanly with no error.
    """
    chapter = _make_chapter(db_session, status="writing")
    fast_llm = _SlowLLM(n_tokens=2, per_token_sleep=0.0)
    disconnect_event = threading.Event()
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=fast_llm,
        writer_persona="测试 Writer 人格",
        disconnect_event=disconnect_event,
    )

    async def consume_all():
        items = []
        async for item in _iterate_sync_stream_cancellable(gen, disconnect_event, chapter.id):
            items.append(item)
        return items

    items = anyio.run(consume_all)

    assert any('"kind": "done"' in item or "event: done" in item for item in items)
    # Normal completion must NOT set disconnect_event — that flag means
    # "client went away", which didn't happen here.
    assert not disconnect_event.is_set()

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "t0t1"


def test_write_stream_disconnect_event_defaults_safely(db_session):
    """`_write_stream` must remain drivable exactly as before when called
    without the new `disconnect_event` parameter (every pre-P8 test in
    `test_sse_cancel.py` / `test_partial_draft_save.py` does this) — the
    default must be a private, never-set Event so behaviour is identical
    to pre-P8.
    """
    chapter = _make_chapter(db_session, status="writing")
    slow_llm = _SlowLLM(n_tokens=20, per_token_sleep=0.02)
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
        writer_persona="测试 Writer 人格",
        # no disconnect_event kwarg — must default safely
    )

    chunks: list[str] = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 3:
            break
    gen.close()
    time.sleep(0.3)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text
