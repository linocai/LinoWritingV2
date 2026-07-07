"""v1.3.2 (LL) P1 — 写作作业化 (writing-as-a-job) worker + registry.

Background / why this exists
----------------------------
Before v1.3.2, ``POST /chapters/{id}/write`` ran the LLM stream *inside the
request generator*: the writer produced tokens on a daemon thread, but the
consumer loop (and the DB writes) rode on the request's own session and was
torn down the instant the client disconnected — and a client disconnect
*cancelled* the whole generation (v1.2.0 P8). That's the behaviour we are
deliberately reversing: leaving the app / switching chapters / the phone
sleeping must NOT abort a write. Only an explicit "停止生成" should.

New model
---------
A ``POST /write`` request now:
  1. builds the writer context + resolves the persona on the request session,
  2. flips ``chapter.status = "writing"`` and commits, then
  3. hands everything to a :class:`WriteJob` whose **own** daemon worker thread
     (with its **own** ``Session`` on the same engine — never the request
     session) runs the generation to completion and writes the terminal state
     to the DB.
The request then merely *subscribes* to the job's live buffer and streams SSE
frames. Client disconnect tears the subscription down; the job keeps running.

Hard platform precondition (defined in PROJECT_PLAN.md §4)
---------------------------------------------------------
This in-process registry is only correct because HZ runs a **single uvicorn
worker**. The systemd unit MUST NEVER gain ``--workers`` / switch to a
multi-process gunicorn — a second process would have its own empty registry and
reattach/cancel would silently miss live jobs. This constraint is also recorded
in ``deploy/README`` and ``hz_info.md`` and logged once at app startup.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Literal

from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.agents.writer import WriterAgent
from app.errors import i18n_upstream
from app.llm.base import LLMClient
from app.models.chapter import Chapter
from app.models.common import utc_now
from app.schemas.chapter import ChapterRead
from app.services.agent_logging import log_agent_call, now_ms

logger = logging.getLogger(__name__)

# How long a *terminal* job lingers in the registry after completion so a late
# reattach can still fetch the exact done/error outcome before we fall back to
# reading DB status. Swept lazily on registry access.
TERMINAL_TTL_SECONDS = 300.0

# Hard ceiling on a single write job's wall-clock lifetime. Aligned with the
# frontend resource timeout (``SSEClient.timeoutIntervalForResource = 3600``).
# A generation that somehow runs past this is treated as an error (conservative
# partial-draft save + error frame) so a wedged upstream can't pin a job — and
# its persistent ``writing`` status — forever.
HARD_DEADLINE_SECONDS = 3600.0

# Bounded wait used by the cancel endpoint (and admin_reset / DELETE when they
# find a live job) after setting ``cancel_event``: give the worker this long to
# reach a terminal state and commit before we return whatever the row shows.
# Plan §4: "有界等终态 5–10s".
CANCEL_WAIT_SECONDS = 8.0

WriteJobPhase = Literal["streaming", "done", "failed", "cancelled"]


class WriteJobConflict(Exception):
    """Raised by :meth:`WriteJobRegistry.reserve` when a live (``streaming``)
    job already exists for the chapter — the caller turns this into a 409."""


class WriteJob:
    """In-memory state of one chapter's write generation.

    Thread-safety: every mutable field that a subscriber (tail generator) or a
    canceller reads is guarded by ``self.condition``. The worker appends tokens
    / marks terminal under the lock and ``notify_all()``s; subscribers ``wait``
    on it. ``cancel_event`` is a plain :class:`threading.Event` (already
    thread-safe) so the LLM client's ``iter_lines`` loop can poll it without the
    condition lock.
    """

    def __init__(
        self,
        chapter_id: str,
        previous_status: str,
        context: dict[str, Any],
        llm: LLMClient,
        writer_persona: str,
    ) -> None:
        self.chapter_id = chapter_id
        self.previous_status = previous_status
        self.context = context
        self.llm = llm
        self.writer_persona = writer_persona

        self.condition = threading.Condition()
        # Final-prose token buffer (never thinking). This is the whole
        # replayable state a reattach snapshot needs.
        self.buffer: list[str] = []
        self.chars = 0
        self.phase: WriteJobPhase = "streaming"
        self.cancel_event = threading.Event()

        # Terminal payloads (populated exactly once when phase leaves
        # "streaming"). ``done``/``cancelled`` carry the post-save ``ChapterRead``
        # dict; ``failed`` carries the SSE error payload dict.
        self.terminal_done_chapter: dict[str, Any] | None = None
        self.terminal_error: dict[str, Any] | None = None
        self.terminal_at: float | None = None

        self.created_at = time.monotonic()
        self.thread: threading.Thread | None = None

        # Transient live "thinking" indicator. Deliberately NOT a replayable
        # buffer (plan §4 🟡3①: reattach loses already-happened thinking, and
        # snapshot never carries it). We hold only the *latest* thinking text
        # plus a monotonically-bumped epoch; live tail subscribers forward the
        # latest text when the epoch advances (rapid reasoning deltas may
        # coalesce into one frame — fine for a transient "模型思考中…" hint).
        self.thinking_epoch = 0
        self.latest_thinking = ""

    @property
    def is_terminal(self) -> bool:
        return self.phase in ("done", "failed", "cancelled")

    def cancel_and_wait(self, timeout: float) -> bool:
        """Signal cancel and block (bounded) until the job reaches a terminal
        state. Returns True iff terminal within ``timeout``."""
        self.cancel_event.set()
        with self.condition:
            deadline = time.monotonic() + timeout
            while not self.is_terminal:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.condition.wait(timeout=remaining)
            return self.is_terminal


class WriteJobRegistry:
    """Process-global ``chapter_id -> WriteJob`` map, guarded by a lock, with
    lazy TTL GC of terminal jobs. One live job per chapter at a time."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, WriteJob] = {}

    def clear(self) -> None:
        """Test helper: drop all tracked jobs (does not stop running daemon
        threads — unit tests join or cancel those themselves)."""
        with self._lock:
            self._jobs.clear()

    def _sweep_locked(self) -> None:
        now = time.monotonic()
        stale = [
            cid
            for cid, job in self._jobs.items()
            if job.is_terminal and job.terminal_at is not None and (now - job.terminal_at) > TERMINAL_TTL_SECONDS
        ]
        for cid in stale:
            del self._jobs[cid]

    def get(self, chapter_id: str) -> WriteJob | None:
        with self._lock:
            self._sweep_locked()
            return self._jobs.get(chapter_id)

    def get_live(self, chapter_id: str) -> WriteJob | None:
        # NOTE (v1.3.2 P1 审后 🔵6): this reads ``job.phase`` while holding the
        # *registry* lock, not the job's own ``condition`` (the worker mutates
        # ``phase`` under the condition, in ``_mark_terminal``). Likewise
        # ``_sweep_locked`` reads ``is_terminal``/``terminal_at`` cross-lock. A
        # single-attribute read/write is atomic under CPython's GIL, and there
        # is exactly ONE worker process (the same systemd single-worker hard
        # constraint recorded in the module docstring + the unit file), so no
        # two threads ever tear a value here. If that GIL/single-worker premise
        # ever changed, every cross-lock ``phase``/``is_terminal`` read would
        # need the condition lock instead.
        job = self.get(chapter_id)
        if job is not None and job.phase == "streaming":
            return job
        return None

    def reserve(
        self,
        chapter_id: str,
        *,
        previous_status: str,
        context: dict[str, Any],
        llm: LLMClient,
        writer_persona: str,
    ) -> WriteJob:
        """Atomically check for a live job and, if none, insert a fresh
        (not-yet-launched) job. Raises :class:`WriteJobConflict` if a live job
        already exists. The worker thread is started separately by
        :meth:`launch` — so the caller can flip ``status=writing`` + commit in
        between and :meth:`abort` on commit failure."""
        with self._lock:
            self._sweep_locked()
            existing = self._jobs.get(chapter_id)
            if existing is not None and existing.phase == "streaming":
                raise WriteJobConflict()
            job = WriteJob(chapter_id, previous_status, context, llm, writer_persona)
            self._jobs[chapter_id] = job
            return job

    def launch(self, job: WriteJob, engine: Engine) -> None:
        thread = threading.Thread(
            target=_run_worker,
            args=(job, engine),
            name=f"write-worker-{job.chapter_id}",
            daemon=True,
        )
        job.thread = thread
        thread.start()

    def abort(self, chapter_id: str, job: WriteJob) -> None:
        """Roll back a reservation whose status-flip commit failed: remove the
        job (if still ours) and mark it terminal so any subscriber that already
        grabbed it unblocks with an error instead of hanging."""
        with self._lock:
            if self._jobs.get(chapter_id) is job:
                del self._jobs[chapter_id]
        _mark_terminal(job, phase="failed", error_payload=_generic_error_payload())


# Module-global singleton (single uvicorn worker — see module docstring).
write_registry = WriteJobRegistry()


class _HardDeadlineExceeded(Exception):
    pass


def _run_worker(job: WriteJob, engine: Engine) -> None:
    """Daemon worker entrypoint. Owns its own Session on ``engine`` (never the
    request session). Guarantees a terminal mark on every path — an escape here
    would leave subscribers waiting forever."""
    session_factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)
    started_ms = now_ms()
    try:
        with session_factory() as session:
            _drive(job, session, started_ms)
    except Exception:  # pragma: no cover - last-resort net; _drive already兜底
        logger.exception("write worker crashed in outer scope for chapter %s", job.chapter_id)
        _mark_terminal(job, phase="failed", error_payload=_generic_error_payload())


def _drive(job: WriteJob, session: Session, started_ms: float) -> None:
    try:
        agent = WriterAgent(job.llm, persona=job.writer_persona)
        for chunk in agent.stream(job.context, cancel_event=job.cancel_event):
            if job.cancel_event.is_set():
                break
            if time.monotonic() - job.created_at > HARD_DEADLINE_SECONDS:
                raise _HardDeadlineExceeded()
            if chunk.kind == "thinking":
                with job.condition:
                    job.latest_thinking = chunk.text
                    job.thinking_epoch += 1
                    job.condition.notify_all()
                continue
            with job.condition:
                job.buffer.append(chunk.text)
                job.chars += len(chunk.text)
                job.condition.notify_all()
        # Loop ended (natural StopIteration or cancel break).
        if job.cancel_event.is_set():
            _finish_cancelled(job, session, started_ms)
        else:
            _finish_done(job, session, started_ms)
    except Exception as exc:
        # A cancel that races an in-flight exception (e.g. socket close raising)
        # should still be treated as a user cancel, not an error Toast.
        if job.cancel_event.is_set():
            _finish_cancelled(job, session, started_ms)
        else:
            _finish_failed(job, session, started_ms, exc)


def _finish_done(job: WriteJob, session: Session, started_ms: float) -> None:
    """Normal completion: persist the full draft as draft_ready. Raises on DB
    failure so ``_drive``'s except folds it into the conservative error path."""
    draft_text = "".join(job.buffer)
    chapter = session.get(Chapter, job.chapter_id)
    if chapter is None:
        # Chapter was deleted mid-write (DELETE saw the live job, set cancel,
        # then deleted). Nothing to persist — just unblock subscribers.
        _mark_terminal(job, phase="done", done_chapter=None)
        return
    # v1.3.2 (LL) P1 审后修复 (最高优先): optimistic-lock guard. If the row is no
    # longer 'writing' it was taken over while we streamed — admin_reset forced a
    # reset, or DELETE/import committed a new authoritative state. A late worker
    # MUST NOT clobber that with its now-stale draft (worst case: overwrite an
    # import's full text ~180s later). Log for audit, hand subscribers the
    # *current* row, and stop. (Reads chapter.status via our own fresh
    # session.get; the takeover was committed on the request session — visible
    # under READ COMMITTED / the shared SQLite connection.)
    if chapter.status != "writing":
        log_agent_call(
            session,
            chapter_id=chapter.id,
            agent_name="writer",
            input_data=job.context,
            output_data=draft_text,
            started_at=started_ms,
            error="superseded: chapter no longer 'writing' (admin_reset/DELETE/import took over) — draft not persisted",
        )
        session.commit()
        session.refresh(chapter)
        _mark_terminal(
            job, phase="done", done_chapter=ChapterRead.model_validate(chapter).model_dump(mode="json")
        )
        return
    chapter.draft_text = draft_text
    chapter.status = "draft_ready"
    chapter.updated_at = utc_now()
    log_agent_call(
        session,
        chapter_id=chapter.id,
        agent_name="writer",
        input_data=job.context,
        output_data=draft_text,
        started_at=started_ms,
    )
    session.commit()
    session.refresh(chapter)
    chapter_dict = ChapterRead.model_validate(chapter).model_dump(mode="json")
    _mark_terminal(job, phase="done", done_chapter=chapter_dict)


def _finish_cancelled(job: WriteJob, session: Session, started_ms: float) -> None:
    """Explicit cancel: conservative partial-draft save, then terminal ``done``
    (the client sees the salvaged chapter, not an error)."""
    chapter_dict: dict[str, Any] | None = None
    try:
        chapter = session.get(Chapter, job.chapter_id)
        if chapter is not None:
            _save_partial_draft(
                session,
                chapter=chapter,
                previous_status=job.previous_status,
                parts=list(job.buffer),
                context=job.context,
                started=started_ms,
                error="stream cancelled by user",
            )
            session.commit()
            session.refresh(chapter)
            chapter_dict = ChapterRead.model_validate(chapter).model_dump(mode="json")
    except Exception:  # 兜底: never leave the job non-terminal
        logger.exception("write worker: cancel save failed for chapter %s", job.chapter_id)
        _safe_rollback(session)
    _mark_terminal(job, phase="cancelled", done_chapter=chapter_dict)


def _finish_failed(job: WriteJob, session: Session, started_ms: float, exc: Exception) -> None:
    """Upstream/LLM error (incl. hard-deadline): conservative partial-draft
    save, then terminal ``failed`` with the SSE error payload."""
    _safe_rollback(session)
    try:
        chapter = session.get(Chapter, job.chapter_id)
        if chapter is not None:
            _save_partial_draft(
                session,
                chapter=chapter,
                previous_status=job.previous_status,
                parts=list(job.buffer),
                context=job.context,
                started=started_ms,
                error=str(exc) or exc.__class__.__name__,
            )
            session.commit()
    except Exception:  # 兜底: still emit a terminal error frame
        logger.exception("write worker: error save failed for chapter %s", job.chapter_id)
        _safe_rollback(session)
    detail = str(exc) or exc.__class__.__name__
    error = i18n_upstream("llm_generic", retryable=getattr(exc, "retryable", True), detail=detail)
    payload = {
        "error": {
            "kind": error.kind,
            "message": error.message,
            "retryable": error.retryable,
            "details": error.details,
        }
    }
    _mark_terminal(job, phase="failed", error_payload=payload)


def _mark_terminal(
    job: WriteJob,
    *,
    phase: WriteJobPhase,
    done_chapter: dict[str, Any] | None = None,
    error_payload: dict[str, Any] | None = None,
) -> None:
    with job.condition:
        if job.is_terminal:
            return  # first terminal wins; defensive against double-finish
        job.phase = phase
        job.terminal_done_chapter = done_chapter
        job.terminal_error = error_payload
        job.terminal_at = time.monotonic()
        job.condition.notify_all()


def _save_partial_draft(
    db: Session,
    *,
    chapter: Chapter,
    previous_status: str,
    parts: list[str],
    context: dict[str, object],
    started: float,
    error: str,
) -> None:
    """Conservative partial-draft save (v1.2.0 P5 policy, moved here for the
    worker in v1.3.2 P1). Does **not** commit — the caller commits.

    Policy (author-approved, deliberately conservative):
      - ``previous_status == "prompt_ready"`` (no prior draft to lose) and
        ``parts`` non-empty → save ``draft_text`` and flip to ``draft_ready``.
      - ``previous_status == "draft_ready"`` (a complete earlier draft exists)
        → never overwrite: log only, leave draft_text/status untouched.
      - ``parts`` empty → restore ``previous_status``, no draft_text write.
      - Any other ``previous_status`` → restore it, log only.

    The ``agent_logs`` row is always written (with ``error``) so partial vs.
    complete generations stay distinguishable for audit.
    """
    joined = "".join(parts) if parts else None
    # v1.3.2 (LL) P1 审后修复 (最高优先): optimistic-lock guard — same reason as
    # ``_finish_done``. If the row is no longer 'writing', admin_reset/DELETE/
    # import took over while we streamed; never overwrite that authoritative
    # status/draft_text with a stale partial. Log the salvage attempt only.
    if chapter.status != "writing":
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="writer",
            input_data=context,
            output_data=joined,
            started_at=started,
            error=f"{error} | superseded: chapter no longer 'writing' — not persisted",
        )
        return
    if parts and previous_status == "prompt_ready":
        chapter.draft_text = joined
        chapter.status = "draft_ready"
        chapter.updated_at = utc_now()
    else:
        chapter.status = previous_status
        chapter.updated_at = utc_now()
    log_agent_call(
        db,
        chapter_id=chapter.id,
        agent_name="writer",
        input_data=context,
        output_data=joined,
        started_at=started,
        error=error,
    )


def _safe_rollback(session: Session) -> None:
    try:
        session.rollback()
    except Exception:  # pragma: no cover - defensive
        pass


def _generic_error_payload() -> dict[str, Any]:
    error = i18n_upstream("llm_generic", retryable=True, detail="内部写作任务异常")
    return {
        "error": {
            "kind": error.kind,
            "message": error.message,
            "retryable": error.retryable,
            "details": error.details,
        }
    }
