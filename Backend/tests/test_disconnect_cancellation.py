"""v1.3.2 (LL) P1 — ``_iterate_sync_stream_cancellable`` with its narrowed
responsibility (plan §4 🟡1).

Post-refactor the wrapper drives the SSE *tail* generator (``_stream_job``),
not the LLM producer. On consumer-task cancellation (client disconnect) it ONLY
closes the tail generator (throwing ``GeneratorExit`` into ``_stream_job``,
which unsubscribes) — it never touches the underlying ``WriteJob``. Because the
wrapper is handed only a generator (no job reference), "disconnect does not
cancel the worker" is now structural; ``test_write_jobs.py`` asserts the
end-to-end version (cancel_event stays unset, worker runs on).

These tests exercise the wrapper directly via ``anyio.run`` (anyio is already a
transitive FastAPI/Starlette dependency).
"""
from __future__ import annotations

import threading
import time

import anyio

from app.routers.chapters import _iterate_sync_stream_cancellable, _stream_job
from app.services.write_jobs import WriteJob, _mark_terminal
from tests.conftest import MockLLMClient


def _job_with_buffer(tokens: list[str]) -> WriteJob:
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")
    with job.condition:
        for t in tokens:
            job.buffer.append(t)
            job.chars += len(t)
    return job


def test_wrapper_forwards_all_frames_on_normal_completion():
    """A terminal job tailed to completion must forward every frame and stop
    cleanly, exactly like Starlette's own iterate_in_threadpool."""
    job = _job_with_buffer(["a", "b"])
    _mark_terminal(job, phase="done", done_chapter={"id": "cid", "status": "draft_ready"})

    async def consume_all() -> list[str]:
        items: list[str] = []
        async for item in _iterate_sync_stream_cancellable(
            _stream_job(job, send_started=True, send_snapshot=True), "cid"
        ):
            items.append(item)
        return items

    items = anyio.run(consume_all)
    joined = "".join(items)
    assert "event: started" in joined
    assert "event: snapshot" in joined
    assert "event: done" in joined


def test_wrapper_tears_down_tail_promptly_on_cancellation():
    """Cancelling the consuming task must close the tail generator quickly —
    bounded, not open-ended — even while the tail is parked in
    condition.wait() for a live (never-terminating here) job."""
    # A live job with no terminal: the tail will block in condition.wait().
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")

    def feeder():
        # Feed a couple tokens so the tail yields, then leave it hanging.
        time.sleep(0.02)
        for t in ["x", "y", "z"]:
            with job.condition:
                job.buffer.append(t)
                job.chars += len(t)
                job.condition.notify_all()
            time.sleep(0.01)

    threading.Thread(target=feeder, daemon=True).start()

    async def consume_then_cancel():
        wrapped = _iterate_sync_stream_cancellable(
            _stream_job(job, send_started=True, send_snapshot=False), "cid"
        )
        async with anyio.create_task_group() as tg:

            async def drive():
                count = 0
                async for _item in wrapped:
                    count += 1
                    if count >= 2:
                        tg.cancel_scope.cancel()

            tg.start_soon(drive)

    started = time.monotonic()
    anyio.run(consume_then_cancel)
    elapsed = time.monotonic() - started
    # Teardown is bounded by the tail's KEEPALIVE_SECONDS wait at worst; it must
    # not hang open-ended.
    assert elapsed < 20.0, f"tail teardown took {elapsed:.2f}s — should be bounded"
    # Critically, the wrapper has no job reference and never set cancel_event.
    assert not job.cancel_event.is_set()
