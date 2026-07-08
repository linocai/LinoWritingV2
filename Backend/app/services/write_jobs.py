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

from app.agents.reviser import ReviserAgent
from app.agents.writer import WriterAgent
from app.errors import i18n_upstream
from app.llm.base import LLMClient
from app.models.chapter import Chapter
from app.models.common import utc_now
from app.schemas.chapter import ChapterRead
from app.services.agent_logging import llm_usage_kwargs, log_agent_call, now_ms

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

# v1.4.0 (MM) P2 — 两遍法字数口径 (PROJECT_PLAN §4 定案 #3, locked). All counts are
# **non-whitespace characters** (``_nonspace_len``, same口径 as the frontend
# ``draftWordCount``). A draft STRICTLY OVER the 上沿 triggers a compression
# revision; ``retry_ceiling`` = 上沿 × 1.10 is the "still too long → one harsher
# retry" threshold.
DEFAULT_WORD_LOW = 2500
DEFAULT_WORD_HIGH = 3500
RETRY_CEILING_FACTOR = 1.10

# v1.4.0 (MM) P2 — non-terminal ``revising`` phase inserted between the draft
# stream and the terminal mark. ``kind`` distinguishes a normal two-pass write
# (``"write"``: stream 初稿 → maybe revise) from a standalone revise-from-
# draft_ready job (``"revise"``: buffer pre-seeded with the existing draft,
# skips streaming, straight into revising). ``revising`` is NOT terminal — the
# ``is_terminal`` set is unchanged so mutual exclusion / TTL treat a revising
# job as still-live.
WriteJobPhase = Literal["streaming", "revising", "done", "failed", "cancelled"]
WriteJobKind = Literal["write", "revise"]


def _nonspace_len(text: str) -> int:
    """Non-whitespace character count — the word-count口径 shared with the
    frontend ``draftWordCount`` (PROJECT_PLAN §4 定案 #3)."""
    return sum(1 for ch in text if not ch.isspace())


def _word_bounds(target: int | None) -> tuple[int, int, int]:
    """Return ``(low, high, retry_ceiling)`` for a ``target_word_count``.

    - target present (>0) → range ``[0.8t, 1.2t]``, 上沿 = ``1.2t``,
      retry ceiling = ``1.2t × 1.10``;
    - target empty/invalid → range ``[2500, 3500]``, 上沿 = ``3500``,
      retry ceiling = ``3850`` (= 3500 × 1.10).
    """
    if target is not None and target > 0:
        low = int(target * 0.8)
        high = int(target * 1.2)
    else:
        low, high = DEFAULT_WORD_LOW, DEFAULT_WORD_HIGH
    retry_ceiling = int(high * RETRY_CEILING_FACTOR)
    return low, high, retry_ceiling


def _target_from_context(context: dict[str, Any]) -> int | None:
    """Resolve the target word count from a writer context (top-level key lifted
    by ``build_writer_context``, with a ``structured_prompt`` fallback for bare
    contexts). Mirrors ``writer._render_word_count_block``'s degradation: non-
    positive / non-numeric / bool → ``None`` (→ default range)."""
    raw = context.get("target_word_count")
    if raw is None:
        raw = (context.get("structured_prompt") or {}).get("target_word_count")
    if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw > 0:
        return int(raw)
    return None


def _clean_str_list(value: Any) -> list[str]:
    return [item.strip() for item in (value or []) if isinstance(item, str) and item.strip()]


class WriteJobConflict(Exception):
    """Raised by :meth:`WriteJobRegistry.reserve` when a live (non-terminal —
    ``streaming`` OR ``revising``, post-🔴1) job already exists for the chapter —
    the caller turns this into a 409."""


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
        *,
        kind: WriteJobKind = "write",
        buffer_seed: list[str] | None = None,
    ) -> None:
        self.chapter_id = chapter_id
        self.previous_status = previous_status
        self.context = context
        self.llm = llm
        self.writer_persona = writer_persona
        self.kind: WriteJobKind = kind

        self.condition = threading.Condition()
        # Final-prose token buffer (never thinking). This is the whole
        # replayable state a reattach snapshot needs. A ``revise`` job seeds it
        # with the existing draft ([draft_text]) so its snapshot / cancel-save
        # always sees the complete原稿 (plan §4 🟡2 + cancel×revising matrix ②).
        self.buffer: list[str] = list(buffer_seed) if buffer_seed else []
        self.chars = sum(len(part) for part in self.buffer)
        # A ``write`` job starts streaming its 初稿; a ``revise`` job has no draft
        # to stream (buffer pre-seeded) so it starts directly in ``revising``.
        self.phase: WriteJobPhase = "revising" if kind == "revise" else "streaming"
        self.cancel_event = threading.Event()

        # Terminal payloads (populated exactly once when phase becomes terminal).
        # ``done``/``cancelled`` carry the post-save ``ChapterRead`` dict;
        # ``failed`` carries the SSE error payload dict. ``revision`` is the
        # two-pass outcome (in_range/revised/unrevised/short) carried by a
        # genuine ``done`` frame only — ``None`` for cancelled/failed (their done
        # frames omit the revision key, per the SSE contract).
        self.terminal_done_chapter: dict[str, Any] | None = None
        self.terminal_error: dict[str, Any] | None = None
        self.terminal_at: float | None = None
        self.revision: str | None = None

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
        #
        # v1.4.0 (MM) P2 (🔴1): "live" is ``not is_terminal`` — a job in the
        # non-terminal ``revising`` phase is STILL live and must keep the
        # chapter mutually excluded (a second write/revise → 409, and
        # admin_reset/DELETE must ``cancel_and_wait`` it first). The old
        # ``phase == "streaming"`` test would have let a revising job be treated
        # as free, letting a racing second job corrupt the row.
        job = self.get(chapter_id)
        if job is not None and not job.is_terminal:
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
        kind: WriteJobKind = "write",
        buffer_seed: list[str] | None = None,
    ) -> WriteJob:
        """Atomically check for a live job and, if none, insert a fresh
        (not-yet-launched) job. Raises :class:`WriteJobConflict` if a live job
        already exists. The worker thread is started separately by
        :meth:`launch` — so the caller can flip ``status=writing`` + commit in
        between and :meth:`abort` on commit failure.

        v1.4.0 (MM) P2: ``kind="revise"`` (buffer seeded with ``[draft_text]``)
        reserves a standalone revise-from-draft_ready job; the live-conflict
        gate is ``not is_terminal`` (🔴1) so it also blocks while another job
        for this chapter is mid-``revising``."""
        with self._lock:
            self._sweep_locked()
            existing = self._jobs.get(chapter_id)
            if existing is not None and not existing.is_terminal:
                raise WriteJobConflict()
            job = WriteJob(
                chapter_id,
                previous_status,
                context,
                llm,
                writer_persona,
                kind=kind,
                buffer_seed=buffer_seed,
            )
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
    # v1.4.0 (MM) P2: a ``revise`` job has no draft to stream — its buffer is
    # pre-seeded with the existing draft and it goes straight into the revising
    # phase.
    if job.kind == "revise":
        _drive_revise(job, session, started_ms)
        return
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
        # Draft stream ended (natural StopIteration or cancel break).
        if job.cancel_event.is_set():
            # Cancel DURING streaming (初稿 未成) → conservative partial-draft
            # save (matrix ③, v1.3.2 behaviour unchanged).
            _finish_cancelled(job, session, started_ms)
        else:
            # 初稿 complete → enter the revising phase (two-pass method).
            _run_revision_phase(job, session, started_ms)
    except Exception as exc:
        # A cancel that races an in-flight exception (e.g. socket close raising)
        # should still be treated as a user cancel, not an error Toast.
        if job.cancel_event.is_set():
            _finish_cancelled(job, session, started_ms)
        else:
            _finish_failed(job, session, started_ms, exc)


def _drive_revise(job: WriteJob, session: Session, started_ms: float) -> None:
    """Revise-kind worker: buffer already holds ``[draft_text]`` and phase is
    ``revising``. Run the revising phase directly (no streaming). DB-write
    failures fold into the same conservative save/error path as a write job;
    revise-CALL failures never reach here (they degrade to ``unrevised`` inside
    ``_run_revision_phase``)."""
    try:
        _run_revision_phase(job, session, started_ms)
    except Exception as exc:
        if job.cancel_event.is_set():
            _finish_cancelled_revising(job, session, started_ms)
        else:
            _finish_failed(job, session, started_ms, exc)


def _run_revision_phase(job: WriteJob, session: Session, started_ms: float) -> None:
    """v1.4.0 (MM) P2 — the revising phase, shared by both kinds.

    On entry the buffer already holds the COMPLETE draft (write: the streamed
    初稿; revise: the seeded ``[draft_text]``) and — for a write job —
    ``job.llm.last_usage`` is the draft stream's usage. Steps:

      1. Flip phase → ``revising`` and ``notify_all`` (tail subscribers emit a
         ``revising`` frame).
      2. If the draft is 严格 > 上沿 → run up to two compression passes
         (``_compress_to_range``); otherwise land it as-is (``in_range`` /
         ``short``) at zero LLM cost — never扩写 (that would发明情节, red line).
      3. Persist the final text as ``draft_ready`` with the ``revision`` outcome
         and mark terminal ``done``.

    Cancel handling (matrix ①/②): a cancel observed at entry or after the
    (blocking) revise call abandons the revision and lands the *complete buffer*
    directly as draft_ready — NOT via the partial-loss ``_save_partial_draft``
    policy, because the buffer here is a whole draft, not a partial.

    A DB-write failure at final persist propagates to the caller
    (``_drive``/``_drive_revise``) → ``_finish_failed``. A revise-CALL failure
    never propagates: it degrades to ``revision="unrevised"`` (fall back to the
    draft) inside ``_compress_to_range``.
    """
    # 1. Enter the revising phase. Guard: a cancel/terminal that already fired
    # elsewhere wins (defensive — the worker is the only mutator here). NOTE (审后
    # 🔵9, 已知接受): the phase flips to ``revising`` UNCONDITIONALLY here, before the
    # length check, so a live subscriber to an in-range write may see a one-frame
    # 「修订中」flash even though no compression happens. Kept deliberately (keeps
    # the revise-kind start-in-revising frame uniform); documented in PROJECT_PLAN
    # §4 P2 as known-accepted.
    with job.condition:
        if job.is_terminal:
            return
        job.phase = "revising"
        job.condition.notify_all()

    draft_text = "".join(job.buffer)

    # Observability (🔵12) + usage 各归各 (审后修复 🔵7): snapshot the初稿 writer
    # agent_log (with the draft stream's usage) ONCE at entry — write kind only (a
    # revise job has no draft call to attribute) — BEFORE any revise call
    # overwrites ``job.llm.last_usage`` and regardless of the revise/cancel/in-range
    # outcome. This is now the SINGLE writer draft log per write job (no longer
    # duplicated into the no-revise ``_persist_revised`` path), so the cancel-
    # landing row need not re-attribute usage → no double-count.
    if job.kind == "write":
        _commit_writer_draft_log(job, session, draft_text, started_ms)

    # A cancel requested at entry → land the complete buffer, cancelled.
    if job.cancel_event.is_set():
        _finish_cancelled_revising(job, session, started_ms)
        return

    draft_len = _nonspace_len(draft_text)
    target = _target_from_context(job.context)
    low, high, retry_ceiling = _word_bounds(target)

    if draft_len <= high:
        # ≤ 上沿 → land as-is (zero LLM cost). short if under the floor (压缩治不了
        # 过短、扩写破红线 → 前端 same as in_range, no badge), else in_range.
        revision = "short" if draft_len < low else "in_range"
        _persist_revised(job, session, final_text=draft_text, revision=revision)
        return

    # > 上沿 → two-pass compression (writer draft usage already snapshotted above).
    final_text, revision = _compress_to_range(
        job, session, draft_text, low=low, high=high, retry_ceiling=retry_ceiling
    )

    # A cancel that arrived while the blocking revise ran → discard the revision,
    # land the complete draft as cancelled (matrix ①/②).
    if job.cancel_event.is_set():
        _finish_cancelled_revising(job, session, started_ms)
        return

    _persist_revised(job, session, final_text=final_text, revision=revision)


def _compress_to_range(
    job: WriteJob,
    session: Session,
    draft_text: str,
    *,
    low: int,
    high: int,
    retry_ceiling: int,
) -> tuple[str, str]:
    """Run up to two compression passes. Returns ``(final_text, revision)`` where
    revision ∈ {``revised``, ``unrevised``}.

    - First pass compresses the draft. Still > ``retry_ceiling`` → one harsher
      retry (续压 the first pass's output).
    - Any revise-CALL exception is swallowed → fall back to the LAST successful
      revision result; no successful revision at all → return the untouched
      draft + ``unrevised`` (plan §4 失败降级 #4: 绝不丢整章).

    Writes + commits an ``agent_name="reviser"`` agent_log after each call
    (success or failure) so token spend / errors stay observable independent of
    the eventual persist/cancel outcome (🔵12)."""
    reviser = ReviserAgent(job.llm, persona=job.writer_persona)
    structured_prompt = job.context.get("structured_prompt") or {}
    # v1.5.0 (NN) P1 — reviser input换源: ``must_happen``→``plot_anchors``
    # (renamed field, same "锚点情节不得丢失" list shape); ``must_not_happen``
    # is deleted entirely (no replacement passed); ``style_directive`` (used to
    # read ``job.context`` directly — the retired global channel) →
    # ``chapter_style`` (read from ``structured_prompt``, same per-chapter
    # source the Writer itself now uses).
    plot_anchors = _clean_str_list(structured_prompt.get("plot_anchors"))
    chapter_style = (structured_prompt.get("chapter_style") or "").strip()

    def _label(harsher: bool) -> str:
        return "harsher" if harsher else "initial"

    def _call(text: str, *, harsher: bool) -> str | None:
        started = now_ms()
        try:
            result = reviser.revise(
                text,
                word_low=low,
                word_high=high,
                plot_anchors=plot_anchors,
                chapter_style=chapter_style,
                harsher=harsher,
            )
        except Exception as exc:  # LLMError / transport — degrade, never abort
            logger.warning(
                "reviser: %s revise pass failed for chapter %s: %s", _label(harsher), job.chapter_id, exc
            )
            _commit_reviser_log(
                job, session, pass_label=_label(harsher), low=low, high=high,
                output=None, started=started, error=str(exc) or exc.__class__.__name__,
            )
            return None
        # v1.4.0 (MM) P2 审后修复 🔴1 (发版硬门, reviewer 已实证): an upstream HTTP 200
        # with ``content: ""`` (content-filter hit / relay truncation / max-token
        # edge) makes ``_extract_content`` return "" WITHOUT raising — a
        # "successful" call whose product is a degenerate/empty draft. Persisting
        # that would set ``draft_text=""`` and SILENTLY WIPE a real chapter (plan
        # 定案#4 红线「绝不丢整章」; unrecoverable on the /revise path). Treat an
        # empty / whitespace-only / absurdly-short result (< 30% of the floor —
        # also blocks a "好的"-style garbage short reply) as a FAILED pass, so it
        # goes through the same degrade chain as an exception: initial degenerate →
        # ``unrevised`` (falls back to the untouched draft); harsher degenerate →
        # keep the first pass's success.
        floor = max(1, int(low * 0.3))
        result_len = _nonspace_len(result)
        if result_len < floor:
            logger.warning(
                "reviser: %s revise pass returned a degenerate result (%d non-space chars < floor %d) "
                "for chapter %s — treating as failure",
                _label(harsher), result_len, floor, job.chapter_id,
            )
            _commit_reviser_log(
                job, session, pass_label=_label(harsher), low=low, high=high,
                output=result, started=started,
                error=f"degenerate revision ({result_len} non-space chars < floor {floor}) — treated as failure",
            )
            return None
        _commit_reviser_log(
            job, session, pass_label=_label(harsher), low=low, high=high,
            output=result, started=started, error=None,
        )
        return result

    best = _call(draft_text, harsher=False)
    if best is None:
        return draft_text, "unrevised"
    # A cancel between passes → skip the (billed) harsher retry; the caller will
    # detect the cancel and land the draft anyway, so this return is moot.
    if job.cancel_event.is_set():
        return best, "revised"
    if _nonspace_len(best) > retry_ceiling:
        harsher_result = _call(best, harsher=True)
        if harsher_result is not None:
            best = harsher_result
        # harsher failed → keep the first pass's result (last successful).
    return best, "revised"


def _persist_revised(
    job: WriteJob,
    session: Session,
    *,
    final_text: str,
    revision: str,
) -> None:
    """Persist ``final_text`` as ``draft_ready`` with the ``revision`` outcome +
    mark terminal ``done``. Optimistic-lock guarded exactly like the old
    ``_finish_done`` (never clobber a row taken over by admin_reset/DELETE/
    import). The 初稿 writer agent_log is written once at revising-phase entry
    (``_commit_writer_draft_log``), not here. Raises on DB failure so the caller
    folds it into the conservative error path."""
    chapter = session.get(Chapter, job.chapter_id)
    if chapter is None:
        # Chapter deleted mid-job — nothing persisted. done_chapter=None and NO
        # revision key (审后 🔵10: revision只在真落库的 done 携带).
        _mark_terminal(job, phase="done", done_chapter=None, revision=None)
        return
    if chapter.status != "writing":
        # Superseded (admin_reset/DELETE/import took over) — never clobber. Hand
        # subscribers the CURRENT row and — 审后修复 🔵10 — DROP the revision key
        # (the compressed text was NOT persisted, so a "revised" badge would
        # mislead). The writer draft log was already committed at revising entry.
        session.refresh(chapter)
        _mark_terminal(
            job,
            phase="done",
            done_chapter=ChapterRead.model_validate(chapter).model_dump(mode="json"),
            revision=None,
        )
        return
    chapter.draft_text = final_text
    chapter.status = "draft_ready"
    chapter.updated_at = utc_now()
    session.commit()
    session.refresh(chapter)
    chapter_dict = ChapterRead.model_validate(chapter).model_dump(mode="json")
    # 审后修复 🟡4 (契约「结果覆盖 buffer 落 draft_ready」): replace the buffer with the
    # persisted final text (under lock) so a late reattach within the terminal TTL
    # snapshots the REVISED draft, not the初稿 — eliminating the初稿→修订稿 flash.
    with job.condition:
        job.buffer = [final_text]
        job.chars = len(final_text)
    _mark_terminal(job, phase="done", done_chapter=chapter_dict, revision=revision)


def _commit_writer_draft_log(job: WriteJob, session: Session, draft_text: str, started_ms: float) -> None:
    """Snapshot the初稿 writer agent_log (with the draft stream's usage) in its
    OWN commit, before the first revise call overwrites ``job.llm.last_usage``
    (observability 🔵12). Best-effort: a log failure is rolled back and ignored
    so it can never abort the revision that follows."""
    try:
        log_agent_call(
            session,
            chapter_id=job.chapter_id,
            agent_name="writer",
            input_data=job.context,
            output_data=draft_text,
            started_at=started_ms,
            **llm_usage_kwargs(job.llm),
        )
        session.commit()
    except Exception:  # 兜底: observability is best-effort, never fatal
        logger.exception("reviser: 初稿 writer draft-usage snapshot log failed for chapter %s", job.chapter_id)
        _safe_rollback(session)


def _commit_reviser_log(
    job: WriteJob,
    session: Session,
    *,
    pass_label: str,
    low: int,
    high: int,
    output: str | None,
    started: float,
    error: str | None,
) -> None:
    """Write + commit one ``agent_name="reviser"`` agent_log (usage read off
    ``job.llm`` right after the revise call). Best-effort: a log-write failure
    is rolled back and ignored (never aborts the revision)."""
    try:
        log_agent_call(
            session,
            chapter_id=job.chapter_id,
            agent_name="reviser",
            input_data={"pass": pass_label, "target_low": low, "target_high": high},
            output_data=output,
            started_at=started,
            error=error,
            **llm_usage_kwargs(job.llm),
        )
        session.commit()
    except Exception:  # 兜底: observability is best-effort, never fatal
        logger.exception("reviser: reviser agent_log write failed for chapter %s", job.chapter_id)
        _safe_rollback(session)


def _finish_cancelled_revising(job: WriteJob, session: Session, started_ms: float) -> None:
    """v1.4.0 (MM) P2 — cancel DURING the revising phase (cancel×revising matrix
    ①/②). The buffer is a COMPLETE draft (write: full 初稿; revise: the original
    draft_text), so — unlike a streaming-phase cancel — we do NOT run the
    conservative partial-loss policy. We land the buffer directly as
    ``draft_ready``:

      ① write job → the complete 初稿 (overwrites any prior draft; the user
         already received a full new draft, just not the compressed one);
      ② revise job → buffer == the original draft_text, so this overwrite is a
         no-op (原稿不丢).

    Optimistic-lock guarded (never clobber a superseded row). The cancelled
    ``done`` frame carries NO revision key (revision stays ``None``).

    审后修复 🔵7 (usage 各归各): this landing log carries **no** LLM usage
    (``tokens_in/out=None``) — the genuine spend during the revising phase is
    already attributed by the 初稿 writer draft log (committed at phase entry) and
    the per-call reviser logs; re-reading ``job.llm.last_usage`` here would
    double-count the last revise call. This row is a pure audit note."""
    draft_text = "".join(job.buffer)
    chapter_dict: dict[str, Any] | None = None
    audit_agent = "writer" if job.kind == "write" else "reviser"
    try:
        chapter = session.get(Chapter, job.chapter_id)
        if chapter is not None:
            if chapter.status == "writing":
                # Only overwrite with a non-empty complete draft — an empty
                # buffer would never reach the revising phase for a write job
                # (draft_len 0 ≤ 上沿 lands as-is, no blocking revise), but guard
                # defensively so we can't wipe a good draft with "".
                if draft_text:
                    chapter.draft_text = draft_text
                chapter.status = "draft_ready"
                chapter.updated_at = utc_now()
                log_agent_call(
                    session,
                    chapter_id=chapter.id,
                    agent_name=audit_agent,
                    input_data=job.context,
                    output_data=draft_text,
                    started_at=started_ms,
                    error="revision cancelled by user — landed complete draft (usage: see writer/reviser rows)",
                )
            else:
                # Superseded — never clobber; log only.
                log_agent_call(
                    session,
                    chapter_id=chapter.id,
                    agent_name=audit_agent,
                    input_data=job.context,
                    output_data=draft_text,
                    started_at=started_ms,
                    error="revision cancelled; superseded (row no longer 'writing') — not persisted",
                )
            session.commit()
            session.refresh(chapter)
            chapter_dict = ChapterRead.model_validate(chapter).model_dump(mode="json")
    except Exception:  # 兜底: never leave the job non-terminal
        logger.exception("write worker: revising-cancel save failed for chapter %s", job.chapter_id)
        _safe_rollback(session)
    _mark_terminal(job, phase="cancelled", done_chapter=chapter_dict)


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
                llm=job.llm,
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
                llm=job.llm,
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
    revision: str | None = None,
) -> None:
    with job.condition:
        if job.is_terminal:
            return  # first terminal wins; defensive against double-finish
        job.phase = phase
        job.terminal_done_chapter = done_chapter
        job.terminal_error = error_payload
        # v1.4.0 (MM) P2: only a genuine ``done`` carries a revision outcome;
        # cancelled/failed leave it ``None`` so their SSE ``done`` frame omits
        # the ``revision`` key.
        job.revision = revision
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
    llm: LLMClient | None = None,
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
    complete generations stay distinguishable for audit. ``llm`` is the same
    client instance the worker just streamed from (``job.llm``) — v1.3.4 快修
    reads its ``last_usage`` (via ``llm_usage_kwargs``) so even a
    cancelled/failed generation's token spend is observable.
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
            **llm_usage_kwargs(llm),
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
        **llm_usage_kwargs(llm),
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
