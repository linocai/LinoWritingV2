"""v1.3.2 (LL) P1 — writing-as-a-job: worker + registry + three endpoints.

Covers the decoupled model where a write survives client disconnect:
  - worker runs to completion on its own session → draft_ready committed;
  - cancel (explicit) → conservative partial-draft save (prompt_ready saves,
    draft_ready never overwrites) and terminal ``done``;
  - the cancel endpoint's bounded wait: terminal within window → terminal row,
    else the still-``writing`` row;
  - reattach: live job → snapshot + tail + terminal; DB fallbacks
    (draft_ready→done / stranded writing→error{stranded_write} / else
    error{no_active_write});
  - start-twice → 409;
  - **disconnect ≠ cancel**: tearing down the tail does NOT set cancel_event and
    the worker keeps running (the whole point of the refactor);
  - hard deadline → conservative save;
  - admin_reset / DELETE see a live job → set cancel_event first;
  - worker terminal-commit failure → job ``failed`` and does not escape.
"""
from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from typing import Any

import anyio

from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.routers import chapters as chapters_router
from app.routers.chapters import _iterate_sync_stream_cancellable, _stream_job
from app.services import write_jobs
from app.services.write_jobs import WriteJob, WriteJobConflict, _mark_terminal, write_registry
from tests.conftest import MockLLMClient


# --------------------------------------------------------------------------
# Mock LLMs
# --------------------------------------------------------------------------


class _FastLLM(MockLLMClient):
    """Yields a fixed list of tokens instantly, then completes."""

    def __init__(self, tokens: list[str]) -> None:
        self.tokens = tokens

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        for t in self.tokens:
            yield StreamChunk(kind="token", text=t)


class _CancelHonoringLLM(MockLLMClient):
    """Streams forever, one token per ``per_token_sleep``, honouring
    ``cancel_event`` (returns as soon as it's set). Records considered tokens."""

    def __init__(self, per_token_sleep: float = 0.02) -> None:
        self.per_token_sleep = per_token_sleep
        self.considered: list[int] = []

    def complete_stream(
        self, *, system: str, user: str, cancel_event: threading.Event | None = None, **kwargs: Any
    ) -> Iterator[StreamChunk]:
        i = 0
        while True:
            if cancel_event is not None and cancel_event.is_set():
                return
            self.considered.append(i)
            yield StreamChunk(kind="token", text=f"t{i}")
            i += 1
            time.sleep(self.per_token_sleep)


class _IgnoreCancelSlowLLM(MockLLMClient):
    """Sleeps before its only token and never checks cancel_event itself —
    used to prove the cancel endpoint returns the still-writing row when the
    worker can't wind down inside the (monkeypatched-tiny) wait window."""

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        time.sleep(0.5)
        yield StreamChunk(kind="token", text="late")


class _RaisingLLM(MockLLMClient):
    def __init__(self, tokens: list[str], message: str = "上游炸了") -> None:
        self.tokens = tokens
        self.message = message

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        for t in self.tokens:
            yield StreamChunk(kind="token", text=t)
        raise RuntimeError(self.message)


class _SlowAfterFirstTokenLLM(MockLLMClient):
    """Yields one token immediately (buffer non-empty), then blocks on the next
    pull long enough for a concurrent admin_reset/DELETE to win the race — used
    to prove the late worker does NOT clobber the takeover."""

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        yield StreamChunk(kind="token", text="半稿")
        time.sleep(0.6)
        yield StreamChunk(kind="token", text="更多")


# --------------------------------------------------------------------------
# Seed helpers
# --------------------------------------------------------------------------


def _seed_chapter(db_session, *, status: str, draft_text: str | None = None) -> Chapter:
    book = Book(title="作业化测试", cover_color="#101010")
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


def _launch(db_session, chapter, llm, *, previous_status: str) -> WriteJob:
    job = write_registry.reserve(
        chapter.id,
        previous_status=previous_status,
        context={},
        llm=llm,
        writer_persona="测试 Writer 人格",
    )
    write_registry.launch(job, db_session.get_bind())
    return job


def _parse_sse(text: str) -> list[tuple[str, dict | None]]:
    out: list[tuple[str, dict | None]] = []
    for block in text.strip().split("\n\n"):
        if not block or block.startswith(":"):
            continue
        lines = block.splitlines()
        event = lines[0].removeprefix("event: ").strip()
        data = json.loads(lines[1].removeprefix("data: ").strip()) if len(lines) > 1 else None
        out.append((event, data))
    return out


# --------------------------------------------------------------------------
# Worker: normal completion + conservative save
# --------------------------------------------------------------------------


def test_worker_completes_and_commits_draft_ready(db_session):
    chapter = _seed_chapter(db_session, status="writing")
    job = _launch(db_session, chapter, _FastLLM(["雨声", "压低了", "呼吸。"]), previous_status="prompt_ready")
    job.thread.join(timeout=5)

    assert not job.thread.is_alive()
    assert job.phase == "done"
    assert job.terminal_done_chapter is not None
    assert job.terminal_done_chapter["status"] == "draft_ready"

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "雨声压低了呼吸。"


def test_worker_cancel_prompt_ready_saves_partial(db_session):
    chapter = _seed_chapter(db_session, status="writing")
    llm = _CancelHonoringLLM(per_token_sleep=0.02)
    job = _launch(db_session, chapter, llm, previous_status="prompt_ready")

    # Wait until the buffer has content, then cancel.
    for _ in range(200):
        with job.condition:
            if job.buffer:
                break
        time.sleep(0.01)
    assert job.cancel_and_wait(5.0)

    assert job.phase == "cancelled"
    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text  # partial draft was salvaged


def test_worker_cancel_draft_ready_does_not_overwrite(db_session):
    original = "断连前已完成的旧稿，必须原样保留。"
    chapter = _seed_chapter(db_session, status="writing", draft_text=original)
    llm = _CancelHonoringLLM(per_token_sleep=0.02)
    job = _launch(db_session, chapter, llm, previous_status="draft_ready")

    for _ in range(200):
        with job.condition:
            if job.buffer:
                break
        time.sleep(0.01)
    assert job.cancel_and_wait(5.0)

    assert job.phase == "cancelled"
    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == original  # untouched


def test_worker_upstream_error_marks_failed_and_saves_partial(db_session):
    chapter = _seed_chapter(db_session, status="writing")
    job = _launch(db_session, chapter, _RaisingLLM(["清", "晨"]), previous_status="prompt_ready")
    job.thread.join(timeout=5)

    assert job.phase == "failed"
    assert job.terminal_error is not None
    assert job.terminal_error["error"]["kind"] == "upstream"
    db_session.refresh(chapter)
    # Conservative save: prompt_ready + partial → draft_ready with the partial.
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "清晨"


def test_worker_hard_deadline_triggers_conservative_save(db_session, monkeypatch):
    chapter = _seed_chapter(db_session, status="writing")
    # Small positive deadline + a slow LLM: the first token lands, then the
    # deadline check on the next iteration trips → conservative save of the
    # partial buffer. (A zero/negative deadline would trip before any token,
    # which correctly saves nothing — not what we're asserting here.)
    monkeypatch.setattr(write_jobs, "HARD_DEADLINE_SECONDS", 0.05)
    job = _launch(db_session, chapter, _CancelHonoringLLM(per_token_sleep=0.1), previous_status="prompt_ready")
    job.thread.join(timeout=5)

    assert job.phase == "failed"
    db_session.refresh(chapter)
    # First token buffered, then deadline check raised → conservative save.
    assert chapter.status == "draft_ready"
    assert chapter.draft_text and chapter.draft_text.startswith("t0")


def test_worker_terminal_commit_failure_marks_failed_and_does_not_escape(db_session, monkeypatch):
    chapter = _seed_chapter(db_session, status="writing")

    def _boom(*_a, **_k):
        raise RuntimeError("commit machinery blew up")

    # Break both the done-path and the conservative-save-path DB write so the
    # worker must fall all the way to the 兜底 terminal mark — without escaping.
    monkeypatch.setattr(write_jobs, "log_agent_call", _boom)
    job = _launch(db_session, chapter, _FastLLM(["一", "二"]), previous_status="prompt_ready")
    job.thread.join(timeout=5)

    assert not job.thread.is_alive()  # thread did not hang / escape
    assert job.phase == "failed"
    assert job.terminal_error is not None


# --------------------------------------------------------------------------
# Registry: mutual exclusion + reservation lifecycle
# --------------------------------------------------------------------------


def test_registry_reserve_conflicts_on_live_job(db_session):
    chapter = _seed_chapter(db_session, status="writing")
    job = _launch(db_session, chapter, _CancelHonoringLLM(0.05), previous_status="prompt_ready")
    try:
        # A second reservation for the same chapter while the first is live → conflict.
        raised = False
        try:
            write_registry.reserve(
                chapter.id, previous_status="prompt_ready", context={}, llm=MockLLMClient(), writer_persona="p"
            )
        except WriteJobConflict:
            raised = True
        assert raised
    finally:
        job.cancel_and_wait(5.0)


def test_registry_abort_marks_terminal(db_session):
    chapter = _seed_chapter(db_session, status="prompt_ready")
    job = write_registry.reserve(
        chapter.id, previous_status="prompt_ready", context={}, llm=MockLLMClient(), writer_persona="p"
    )
    write_registry.abort(chapter.id, job)
    assert job.is_terminal
    assert job.phase == "failed"
    assert write_registry.get(chapter.id) is None


# --------------------------------------------------------------------------
# _stream_job tail generator (deterministic, no TestClient)
# --------------------------------------------------------------------------


def test_stream_job_snapshot_then_terminal_done():
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")
    with job.condition:
        job.buffer.extend(["前半", "后半"])
        job.chars = len("前半后半")
    _mark_terminal(job, phase="done", done_chapter={"id": "cid", "status": "draft_ready"})

    frames = _parse_sse("".join(_stream_job(job, send_started=True, send_snapshot=True)))
    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert names[1] == "snapshot"
    snapshot = [d for n, d in frames if n == "snapshot"][0]
    assert snapshot["buffer"] == "前半后半"
    assert snapshot["chars"] == len("前半后半")
    assert names[-1] == "done"


def test_stream_job_terminal_failed_emits_error():
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")
    _mark_terminal(job, phase="failed", error_payload={"error": {"kind": "upstream", "message": "x"}})
    frames = _parse_sse("".join(_stream_job(job, send_started=True, send_snapshot=True)))
    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert names[-1] == "error"


def test_stream_job_live_tail_forwards_tokens_then_done():
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")

    def feeder():
        time.sleep(0.02)
        for tok in ["a", "b"]:
            with job.condition:
                job.buffer.append(tok)
                job.chars += len(tok)
                job.condition.notify_all()
            time.sleep(0.01)
        _mark_terminal(job, phase="done", done_chapter={"id": "cid", "status": "draft_ready"})

    t = threading.Thread(target=feeder, daemon=True)
    t.start()
    frames = _parse_sse("".join(_stream_job(job, send_started=True, send_snapshot=False)))
    t.join(timeout=5)
    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert names.count("token") == 2
    assert "progress" in names
    assert names[-1] == "done"


# --------------------------------------------------------------------------
# disconnect ≠ cancel (the core reversal)
# --------------------------------------------------------------------------


def test_disconnect_tears_down_tail_but_does_not_cancel_worker(db_session):
    """Cancelling the *consuming* task (client disconnect) must close the tail
    subscription WITHOUT setting the job's cancel_event — the worker keeps
    running to completion."""
    chapter = _seed_chapter(db_session, status="writing")
    llm = _CancelHonoringLLM(per_token_sleep=0.02)
    job = _launch(db_session, chapter, llm, previous_status="prompt_ready")

    async def consume_then_cancel():
        wrapped = _iterate_sync_stream_cancellable(
            _stream_job(job, send_started=True, send_snapshot=False), chapter.id
        )
        async with anyio.create_task_group() as tg:

            async def drive():
                count = 0
                async for _item in wrapped:
                    count += 1
                    if count >= 2:
                        tg.cancel_scope.cancel()

            tg.start_soon(drive)

    anyio.run(consume_then_cancel)

    # The subscription was torn down, but the worker's cancel_event must NOT
    # have been set — disconnect is not cancel.
    assert not job.cancel_event.is_set(), "client disconnect must NOT cancel the worker (v1.3.2 reversal)"
    # The worker is still streaming (or will run to completion); let it finish.
    job.cancel_event.set()  # test cleanup only (not part of the assertion)
    job.thread.join(timeout=5)


# --------------------------------------------------------------------------
# Endpoints via TestClient
# --------------------------------------------------------------------------


def _seed_book_chapter_via_client(client, auth_headers, *, status_prompt_ready: bool = True):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "长夜", "cover_color": "#111111"}).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角", "frozen_fields": {"core_traits": "谨慎"}, "live_fields": {}},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "雨夜", "user_prompt": "林夕在山洞找到关键线索。"},
    ).json()
    if status_prompt_ready:
        chapter = client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers).json()
    return book, chapter


def test_start_write_twice_conflicts(client, auth_headers):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    # Reserve a live job to simulate an in-flight write (phase=streaming).
    write_registry.reserve(
        chapter["id"], previous_status="prompt_ready", context={}, llm=MockLLMClient(), writer_persona="p"
    )
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"


def test_reattach_draft_ready_no_job_emits_done(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    # Drive a normal write to completion first (default MockLLM → draft_ready).
    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers) as r:
        "".join(r.iter_text())
    write_registry.clear()  # drop the terminal job so reattach hits the DB fallback

    with client.stream("GET", f"/api/v1/chapters/{chapter['id']}/write/stream", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))
    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert names[-1] == "done"
    done = [d for n, d in frames if n == "done"][0]
    assert done["chapter"]["status"] == "draft_ready"


def test_reattach_stranded_writing_no_job_emits_stranded_write(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    # Force the DB row into 'writing' with no registry job (restart orphan).
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    with client.stream("GET", f"/api/v1/chapters/{chapter['id']}/write/stream", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))
    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert ("error", {"kind": "stranded_write"}) in frames


def test_reattach_no_active_write_emits_no_active_write(client, auth_headers):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)  # prompt_ready, no job
    with client.stream("GET", f"/api/v1/chapters/{chapter['id']}/write/stream", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))
    assert ("error", {"kind": "no_active_write"}) in frames


def test_cancel_live_job_returns_terminal_row(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    job = _launch(db_session, row, _CancelHonoringLLM(per_token_sleep=0.02), previous_status="prompt_ready")
    for _ in range(200):
        with job.condition:
            if job.buffer:
                break
        time.sleep(0.01)

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/write/cancel", headers=auth_headers)
    assert resp.status_code == 200
    # prompt_ready + partial → conservative save → draft_ready terminal row.
    assert resp.json()["status"] == "draft_ready"
    assert job.phase == "cancelled"


def test_cancel_returns_writing_row_when_worker_misses_window(client, auth_headers, db_session, monkeypatch):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    monkeypatch.setattr(chapters_router, "CANCEL_WAIT_SECONDS", 0.05)
    job = _launch(db_session, row, _IgnoreCancelSlowLLM(), previous_status="prompt_ready")

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/write/cancel", headers=auth_headers)
    assert resp.status_code == 200
    # Worker is still sleeping past the tiny wait window → row still 'writing'.
    assert resp.json()["status"] == "writing"
    # Let the worker wind down before teardown drops the tables.
    job.thread.join(timeout=5)


def test_cancel_no_live_job_stranded_writing_resets_conservatively(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    row.draft_text = "残稿"
    db_session.commit()

    resp = client.post(f"/api/v1/chapters/{chapter['id']}/write/cancel", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "draft_ready"  # had draft_text → draft_ready


def test_cancel_no_active_write_is_noop(client, auth_headers):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)  # prompt_ready
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/write/cancel", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "prompt_ready"  # unchanged


# --------------------------------------------------------------------------
# admin_reset / DELETE set cancel_event on a live job first (🟡4)
# --------------------------------------------------------------------------


def test_admin_reset_cancels_live_job_first(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    job = _launch(db_session, row, _CancelHonoringLLM(per_token_sleep=0.02), previous_status="prompt_ready")

    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset", headers=auth_headers, json={"target_status": "prompt_ready"}
    )
    assert resp.status_code == 200
    assert job.cancel_event.is_set()  # escape hatch cancelled the worker first
    assert resp.json()["status"] == "prompt_ready"


def test_late_worker_finish_does_not_clobber_admin_reset(client, auth_headers, db_session, monkeypatch):
    """审后修复 #1 (最高优先): a worker that finishes AFTER admin_reset (because it
    blew past the bounded cancel wait) must NOT overwrite the reset row with its
    stale partial draft."""
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    # Tiny cancel-wait so admin_reset does NOT wait for the (slow) worker.
    monkeypatch.setattr(chapters_router, "CANCEL_WAIT_SECONDS", 0.02)
    job = _launch(db_session, row, _SlowAfterFirstTokenLLM(), previous_status="prompt_ready")
    # Wait until the worker has buffered its first token (the clobber material).
    for _ in range(200):
        with job.condition:
            if job.buffer:
                break
        time.sleep(0.01)

    # admin_reset forces prompt_ready while the worker is still blocked in sleep.
    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset", headers=auth_headers, json={"target_status": "prompt_ready"}
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "prompt_ready"

    # Let the late worker finish — it must observe status != 'writing' and skip
    # the draft write.
    job.thread.join(timeout=5)
    assert job.is_terminal
    db_session.refresh(row)
    assert row.status == "prompt_ready", "late worker clobbered the admin_reset"
    assert row.draft_text is None, "late worker persisted a stale partial over the reset"


def test_delete_cancels_live_job_first(client, auth_headers, db_session):
    _book, chapter = _seed_book_chapter_via_client(client, auth_headers)
    row = db_session.get(Chapter, chapter["id"])
    row.status = "writing"
    db_session.commit()

    job = _launch(db_session, row, _CancelHonoringLLM(per_token_sleep=0.02), previous_status="prompt_ready")

    resp = client.delete(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers)
    assert resp.status_code == 204
    assert job.cancel_event.is_set()
    # Chapter is gone; a late worker finish must no-op on the missing row.
    job.thread.join(timeout=5)
    # Verify via a fresh request (db_session's identity map would cache the
    # already-loaded row, so query the API instead).
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).status_code == 404
