from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator, Iterator
from typing import Literal

import anyio
from fastapi import APIRouter, Body, Depends, Query, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.agents.extractor import ExtractorAgent
from app.agents.prompt_expander import PromptExpanderAgent
from app.db import get_db
from app.errors import AppError, i18n_conflict, i18n_not_found, i18n_upstream
from app.llm.base import (
    LLMClient,
    get_expander_llm_client,
    get_extractor_llm_client,
    get_llm_client,
    get_writer_llm_client,
)
from app.llm.errors import LLMError
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.common import utc_now
from app.models.timeline_event import TimelineEvent
from app.schemas.chapter import (
    ChapterAdminResetRequest,
    ChapterCreate,
    ChapterImportRequest,
    ChapterPatch,
    ChapterRead,
    ChapterSummary,
)
from app.services.agent_logging import llm_usage_kwargs, log_agent_call, now_ms
from app.services.chapter_state import ensure_chapter_status
from app.services.context_pack import build_expander_context, build_extractor_context, build_writer_context
from app.services.exporter import (
    build_content_disposition,
    build_filename,
    export_chapter_markdown,
    export_chapter_txt,
)
from app.services.extractor_apply import apply_extractor_output
from app.services.personas import get_persona
from app.services.write_jobs import (
    CANCEL_WAIT_SECONDS,
    WriteJob,
    WriteJobConflict,
    write_registry,
)

# v0.7 §5.F — same Literal trick as in books.py.
ExportFormat = Literal["markdown", "txt"]

router = APIRouter(tags=["chapters"])
KEEPALIVE_SECONDS = 15
logger = logging.getLogger(__name__)

# Explicit allowlist for PATCH /chapters/{id}. ChapterPatch schema already
# only exposes these four fields, but we re-assert it at the router level
# so that adding a new field to the schema later (e.g. status, source,
# focus_traits) does NOT silently become a writable mass-assignment vector.
# See §5.P.1 F.
PATCHABLE_CHAPTER_FIELDS = frozenset(
    {"title", "user_prompt", "structured_prompt", "draft_text"}
)


@router.get("/books/{book_id}/chapters")
def list_chapters(book_id: str, db: Session = Depends(get_db)) -> dict[str, list[ChapterSummary]]:
    _ensure_book(db, book_id)
    chapters = db.scalars(select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)).all()
    return {"items": [ChapterSummary.model_validate(chapter) for chapter in chapters]}


@router.post("/books/{book_id}/chapters", response_model=ChapterRead, status_code=status.HTTP_201_CREATED)
def create_chapter(book_id: str, payload: ChapterCreate, db: Session = Depends(get_db)) -> ChapterRead:
    _ensure_book(db, book_id)
    max_index = db.scalar(select(func.max(Chapter.index)).where(Chapter.book_id == book_id)) or 0
    chapter = Chapter(book_id=book_id, index=max_index + 1, title=payload.title, user_prompt=payload.user_prompt)
    db.add(chapter)
    db.commit()
    db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


@router.get("/chapters/{chapter_id}", response_model=ChapterRead)
def get_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    return ChapterRead.model_validate(_get_chapter(db, chapter_id))


@router.patch("/chapters/{chapter_id}", response_model=ChapterRead)
def patch_chapter(chapter_id: str, payload: ChapterPatch, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = _get_chapter(db, chapter_id)
    incoming = payload.model_dump(exclude_unset=True)
    # Defence in depth — even if ChapterPatch later gains a field, we
    # refuse to assign anything outside the allowlist. Unknown keys are
    # silently ignored (Pydantic already rejected them at parse time
    # under the default ``extra='ignore'`` config, but if that ever
    # changes we want this layer too).
    for key, value in incoming.items():
        if key not in PATCHABLE_CHAPTER_FIELDS:
            continue
        if isinstance(value, BaseModel):
            value = value.model_dump(exclude_none=True)
        setattr(chapter, key, value)
    chapter.updated_at = utc_now()
    db.commit()
    db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


@router.delete("/chapters/{chapter_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_chapter(chapter_id: str, db: Session = Depends(get_db)) -> Response:
    chapter = _get_chapter(db, chapter_id)
    # v1.3.2 (LL) P1 (🟡4): a live write worker holds its own session and will
    # try to commit draft_ready to this chapter. Cancel it and wait (bounded)
    # for it to wind down BEFORE deleting, so the worker doesn't resurrect / err
    # on a row we just removed. If the worker misses the window it will find the
    # chapter gone (session.get → None) and no-op safely.
    live = write_registry.get_live(chapter_id)
    if live is not None:
        live.cancel_and_wait(CANCEL_WAIT_SECONDS)
    db.delete(chapter)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/chapters/{chapter_id}/expand", response_model=ChapterRead)
def expand_chapter(
    chapter_id: str,
    force: bool = Query(default=False),
    db: Session = Depends(get_db),
    # M-1: PromptExpanderAgent → expander key (fallback to generic).
    llm: LLMClient = Depends(get_expander_llm_client),
) -> ChapterRead:
    chapter = _get_chapter(db, chapter_id)
    if not force:
        ensure_chapter_status(chapter, {"draft", "prompt_ready"}, "expand")
    book = _get_book(db, chapter.book_id)
    context = build_expander_context(db, book, chapter)
    started = now_ms()
    try:
        structured_prompt = PromptExpanderAgent(llm, persona=get_persona(db, "expander")).expand(context)
        chapter.structured_prompt = structured_prompt
        chapter.status = "prompt_ready"
        chapter.updated_at = utc_now()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="expander",
            input_data=context,
            output_data=structured_prompt,
            started_at=started,
            **llm_usage_kwargs(llm),
        )
        db.commit()
    except (LLMError, ValueError) as exc:
        db.rollback()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="expander",
            input_data=context,
            started_at=started,
            error=str(exc),
            **llm_usage_kwargs(llm),
        )
        db.commit()
        raise i18n_upstream(
            "llm_generic",
            retryable=getattr(exc, "retryable", False),
            detail=str(exc),
        ) from exc
    db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


@router.post("/chapters/{chapter_id}/write")
def write_chapter(
    chapter_id: str,
    db: Session = Depends(get_db),
    # M-1: WriterAgent → writer key (fallback to generic).
    llm: LLMClient = Depends(get_writer_llm_client),
) -> StreamingResponse:
    """v1.3.2 (LL) P1 — start a *decoupled* write job and stream its tail.

    Unlike the pre-v1.3.2 design (LLM ran inside this request generator and a
    client disconnect cancelled it), the generation now runs on a
    :class:`WriteJob`'s own daemon worker with its own DB session. This request
    only flips ``status=writing``, launches the worker, and subscribes to the
    live buffer from offset 0. A client disconnect merely tears down that
    subscription — the worker runs to completion regardless. Cancelling is now
    an explicit action (``POST /write/cancel``).

    Mutual exclusion: if a live (``streaming``) job already exists for this
    chapter → 409 ``chapter_write_in_progress`` (status may already be
    ``writing`` too, but the registry is the authoritative gate).
    """
    chapter = _get_chapter(db, chapter_id)
    ensure_chapter_status(chapter, {"prompt_ready", "draft_ready"}, "write")
    if write_registry.get_live(chapter_id) is not None:
        raise i18n_conflict("chapter_write_in_progress")
    book = _get_book(db, chapter.book_id)
    context = build_writer_context(db, book, chapter)
    # Resolve the Writer persona (DB, App-editable) up front — the worker runs
    # on its own thread/session and must not touch the request session.
    writer_persona = get_persona(db, "writer")
    previous_status = chapter.status

    # Reserve the job slot atomically FIRST (raises on a live-job race), so a
    # conflict never strands us with status already flipped to writing.
    try:
        job = write_registry.reserve(
            chapter_id,
            previous_status=previous_status,
            context=context,
            llm=llm,
            writer_persona=writer_persona,
        )
    except WriteJobConflict:
        raise i18n_conflict("chapter_write_in_progress")

    # Persistent "writing" marker (drives 409 mutual exclusion for import,
    # admin_reset's escape-hatch, and the reattach fallback). On commit failure
    # abort the reservation so no orphan job lingers.
    try:
        chapter.status = "writing"
        chapter.updated_at = utc_now()
        db.commit()
    except Exception:
        write_registry.abort(chapter_id, job)
        raise

    # Worker binds its own session to the *same* engine as this request — never
    # the request session. ``db.get_bind()`` keeps this correct under tests
    # (per-test engine) and prod (SessionLocal engine) alike.
    write_registry.launch(job, db.get_bind())

    return StreamingResponse(
        _iterate_sync_stream_cancellable(
            _stream_job(job, send_started=True, send_snapshot=False),
            chapter_id,
        ),
        media_type="text/event-stream",
    )


@router.get("/chapters/{chapter_id}/write/stream")
def reattach_write_stream(
    chapter_id: str,
    db: Session = Depends(get_db),
) -> StreamingResponse:
    """v1.3.2 (LL) P1 — reattach to an in-flight (or just-finished) write.

    Every branch opens with a ``started`` frame. When a job exists (live or a
    terminal one still within its registry TTL) we replay the buffer via a
    one-shot ``snapshot`` (final prose only, never thinking), then tail to the
    terminal frame. With no job we fall back to the DB status:
      - ``draft_ready``           → ``done`` (job already GC'd, work is safe);
      - ``writing`` (no job)      → ``error{kind:"stranded_write"}`` (a restart
                                    orphan — points the user at 强制重置);
      - anything else             → ``error{kind:"no_active_write"}`` (frontend
                                    silently drops to idle, no Toast).
    """
    chapter = _get_chapter(db, chapter_id)
    job = write_registry.get(chapter_id)
    if job is not None:
        return StreamingResponse(
            _iterate_sync_stream_cancellable(
                _stream_job(job, send_started=True, send_snapshot=True),
                chapter_id,
            ),
            media_type="text/event-stream",
        )

    if chapter.status == "draft_ready":
        chapter_dict = ChapterRead.model_validate(chapter).model_dump(mode="json")
        frames = [("started", {"chapter_id": chapter_id}), ("done", {"chapter": chapter_dict})]
    elif chapter.status == "writing":
        # Live "writing" status but no job in the registry → the worker was lost
        # to a process restart. Nothing can recover it here; the client shows
        # the 强制重置 escape hatch.
        frames = [("started", {"chapter_id": chapter_id}), ("error", {"kind": "stranded_write"})]
    else:
        frames = [("started", {"chapter_id": chapter_id}), ("error", {"kind": "no_active_write"})]
    return StreamingResponse(_single_frame_stream(frames), media_type="text/event-stream")


@router.post("/chapters/{chapter_id}/write/cancel", response_model=ChapterRead)
def cancel_write(
    chapter_id: str,
    db: Session = Depends(get_db),
) -> ChapterRead:
    """v1.3.2 (LL) P1 — the *only* way to actually stop a write.

    Live job → set ``cancel_event`` (which propagates through
    ``WriterAgent.stream`` → the LLM client's ``iter_lines`` loop → closing the
    upstream socket), then wait up to ``CANCEL_WAIT_SECONDS`` for the worker to
    reach terminal (conservative partial-draft save committed). Return the
    terminal row if reached, otherwise the current row (still ``writing`` — the
    frontend keeps reconciling). No live job → idempotent: reset a restart
    orphan conservatively, else no-op.
    """
    chapter = _get_chapter(db, chapter_id)
    job = write_registry.get_live(chapter_id)
    if job is not None:
        job.cancel_and_wait(CANCEL_WAIT_SECONDS)
        # Pick up whatever the worker committed (terminal) — or the unchanged
        # writing row if it didn't finish within the window.
        db.refresh(chapter)
        return ChapterRead.model_validate(chapter)

    # No live job. If the chapter is stranded in ``writing`` (restart orphan,
    # or a terminal job already GC'd), reset it conservatively so the user
    # isn't stuck. Otherwise this is a no-op (idempotent).
    if chapter.status == "writing":
        chapter.status = "draft_ready" if (chapter.draft_text or "").strip() else "prompt_ready"
        chapter.updated_at = utc_now()
        db.commit()
        db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


class _SyncStreamStopIteration(Exception):
    """Private stand-in for ``StopIteration`` when crossing an ``await``
    boundary (worker thread → event loop). Mirrors
    ``starlette.concurrency._StopIteration`` — a real ``StopIteration``
    escaping a coroutine is converted by Python (PEP 479) into
    ``RuntimeError: coroutine raised StopIteration`` instead of propagating
    as-is, so it must be caught and re-thrown as an ordinary ``Exception``
    before it can cross that boundary.
    """


def _next_or_stop(iterator: Iterator[str]) -> str:
    try:
        return next(iterator)
    except StopIteration:
        raise _SyncStreamStopIteration from None


async def _iterate_sync_stream_cancellable(
    sync_iter: Iterator[str], chapter_id: str
) -> AsyncIterator[str]:
    """Drive a sync SSE tail generator (``_stream_job``) from async code
    without Starlette's default shielded ``iterate_in_threadpool`` behaviour.

    v1.3.2 (LL) P1 — responsibility deliberately narrowed (plan §4 🟡1). On
    cancellation of the *consuming* task (client disconnect, detected by
    Starlette's ``listen_for_disconnect`` + cancel scope) this ONLY closes the
    tail generator (throwing ``GeneratorExit`` into ``_stream_job``, which
    unsubscribes and stops keepalives). It **never** touches the underlying
    :class:`WriteJob`: no ``cancel_event`` is set, no partial-draft save runs —
    the worker keeps generating. Disconnect ≠ cancel (that reversal is the whole
    point of writing-as-a-job). Real cancellation goes through
    ``POST /write/cancel``.

    ``abandon_on_cancel=True`` means a cancelled awaiting task doesn't shield
    the blocked ``next()`` call; ``_safe_close`` then retries ``.close()`` past
    the transient ``ValueError: generator already executing`` until the parked
    ``next()`` (a ``condition.wait(timeout=KEEPALIVE)``) returns.
    """

    async def _safe_close() -> None:
        # Bounded retry: worst case the tail is parked in a
        # KEEPALIVE_SECONDS condition.wait(); ~20s ceiling is generous headroom.
        # Giving up here only leaks a soon-to-exit tail generator (the WriteJob
        # and its worker are entirely decoupled and unaffected), but log it for
        # triage.
        for _attempt in range(200):
            try:
                await anyio.to_thread.run_sync(sync_iter.close, abandon_on_cancel=True)
                return
            except ValueError as exc:
                if "already executing" not in str(exc):
                    raise
                await anyio.sleep(0.1)
        logger.error(
            "chapter %s: _safe_close gave up after ~20s retrying tail "
            "generator.close() (still 'already executing') — subscription "
            "teardown deferred (the write job itself is unaffected)",
            chapter_id,
        )

    completed_normally = False
    try:
        while True:
            try:
                item = await anyio.to_thread.run_sync(_next_or_stop, sync_iter, abandon_on_cancel=True)
            except _SyncStreamStopIteration:
                completed_normally = True
                return
            yield item
    finally:
        if not completed_normally:
            # Reached via cancellation (client disconnect) or an unexpected
            # exception — close the tail so its condition.wait() unwinds. Shield
            # the cleanup so a just-cancelled task can still finish it (bounded
            # by _safe_close's own retry cap).
            with anyio.CancelScope(shield=True):
                await _safe_close()


def _stream_job(job: WriteJob, *, send_started: bool, send_snapshot: bool) -> Iterator[str]:
    """Tail a :class:`WriteJob` as SSE frames. Reads only in-memory job state
    (never the DB). ``send_started`` opens with a ``started`` frame;
    ``send_snapshot`` (reattach only) replays the buffer-so-far via one
    ``snapshot`` frame (final prose only, no thinking). Then it emits ``token``/
    ``progress`` as the buffer grows, ``thinking`` when the transient indicator
    advances, ``: keepalive`` on idle, and finally the terminal ``done``/
    ``error`` frame.

    Closing this generator (client disconnect, via the wrapper) is a plain
    unsubscribe: it must NOT set ``cancel_event`` or save anything (plan §4 🟡1).
    """
    if send_started:
        yield _sse("started", {"chapter_id": job.chapter_id})

    cursor = 0
    thinking_seen = 0
    if send_snapshot:
        with job.condition:
            snapshot_text = "".join(job.buffer)
            chars = job.chars
            cursor = len(job.buffer)
            thinking_seen = job.thinking_epoch  # skip already-happened thinking
        yield _sse("snapshot", {"buffer": snapshot_text, "chars": chars})

    while True:
        with job.condition:
            while (
                cursor >= len(job.buffer)
                and job.thinking_epoch == thinking_seen
                and not job.is_terminal
            ):
                if not job.condition.wait(timeout=KEEPALIVE_SECONDS):
                    break  # timed out — emit keepalive below if nothing new
            new_tokens = job.buffer[cursor:]
            cursor = len(job.buffer)
            chars = job.chars
            thinking_text = job.latest_thinking if job.thinking_epoch != thinking_seen else None
            thinking_seen = job.thinking_epoch
            terminal = job.is_terminal
            phase = job.phase
            done_chapter = job.terminal_done_chapter
            error_payload = job.terminal_error
            timed_out = not new_tokens and thinking_text is None and not terminal

        if timed_out:
            yield ": keepalive\n\n"
            continue
        if thinking_text:
            yield _sse("thinking", {"text": thinking_text})
        for token in new_tokens:
            yield _sse("token", {"text": token})
        if new_tokens:
            yield _sse("progress", {"chars": chars})
        if terminal:
            # Buffer is final once terminal is set under the lock, so all tokens
            # are already drained above. Emit the terminal frame and stop.
            if phase == "failed":
                yield _sse("error", error_payload or {})
            else:  # done or cancelled → the client sees a normal `done`
                yield _sse("done", {"chapter": done_chapter})
            return


def _single_frame_stream(frames: list[tuple[str, dict[str, object]]]) -> Iterator[str]:
    """Emit a fixed sequence of SSE frames (reattach DB-fallback branches)."""
    for event, data in frames:
        yield _sse(event, data)


@router.post("/chapters/{chapter_id}/finalize")
def finalize_chapter(
    chapter_id: str,
    db: Session = Depends(get_db),
    # M-1: ExtractorAgent → extractor key (fallback to generic).
    llm: LLMClient = Depends(get_extractor_llm_client),
) -> dict[str, object]:
    chapter = _get_chapter(db, chapter_id)
    ensure_chapter_status(chapter, {"draft_ready"}, "finalize")
    book = _get_book(db, chapter.book_id)
    context = build_extractor_context(db, book, chapter)
    started = now_ms()
    try:
        extractor_output = ExtractorAgent(llm, persona=get_persona(db, "extractor")).extract(context)
        updated_character_ids, added_event_ids = apply_extractor_output(db, chapter, extractor_output)
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            output_data=extractor_output,
            started_at=started,
            **llm_usage_kwargs(llm),
        )
        db.commit()
    except (LLMError, AppError, ValueError) as exc:
        db.rollback()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            started_at=started,
            error=str(exc),
            **llm_usage_kwargs(llm),
        )
        db.commit()
        if isinstance(exc, AppError):
            raise
        raise i18n_upstream(
            "llm_generic",
            retryable=getattr(exc, "retryable", False),
            detail=str(exc),
        ) from exc
    db.refresh(chapter)
    return {
        "chapter": ChapterRead.model_validate(chapter),
        "updated_character_ids": updated_character_ids,
        "added_event_ids": added_event_ids,
    }


@router.post("/chapters/{chapter_id}/extract")
def extract_chapter(
    chapter_id: str,
    db: Session = Depends(get_db),
    # v0.9.3 §5.DI — manual extract reuses the extractor key, same as
    # /finalize and /import (run_extractor=True).
    llm: LLMClient = Depends(get_extractor_llm_client),
) -> dict[str, object]:
    """Manually run the Extractor on an already-finalized chapter.

    v0.9.3 §5.DI — import/extract decoupling. Import now only lands the
    draft (→ finalized, no LLM). Extracting characters / timeline is a
    separate, manually-triggered action. Pre-conditions: chapter must be
    ``finalized`` (409 otherwise) and have non-empty ``draft_text``
    (``no_draft_to_extract`` 409 otherwise).

    Repeatable: the chapter's old timeline events are deleted first
    (mirroring ``/reopen``) so re-running never piles up duplicate events;
    live_fields are simply overwritten by the new Extractor output. The
    chapter stays ``finalized`` throughout — only character cards + timeline
    are rewritten. On failure ``db.rollback()`` leaves draft_text / status
    untouched (they were never modified). Response envelope matches
    ``/finalize`` and ``/import``.
    """
    chapter = _get_chapter(db, chapter_id)
    ensure_chapter_status(chapter, {"finalized"}, "extract")
    if (chapter.draft_text or "").strip() == "":
        raise i18n_conflict("no_draft_to_extract")
    book = _get_book(db, chapter.book_id)

    # Clear this chapter's old timeline first so repeated extraction is
    # idempotent (no duplicate events). Mirrors reopen_chapter's cleanup.
    #
    # NOTE (reviewer 🔵#1): the *real* dedup point shared with /finalize and
    # /import is the identical `delete(TimelineEvent)` inside
    # `apply_extractor_output` (extractor_apply.py). On the success path this
    # pre-delete is therefore covered by that later delete; on the failure path
    # it is undone by `db.rollback()`. Net effect of this block alone is zero —
    # we keep it because PROJECT_PLAN §5.DI.2 step 1 explicitly requires it as a
    # mirror of /reopen's cleanup (defensive: if apply ever stops deleting, this
    # still guarantees no duplicate events on repeated extraction). Do not remove.
    db.execute(delete(TimelineEvent).where(TimelineEvent.chapter_id == chapter.id))
    db.flush()

    context = build_extractor_context(db, book, chapter)
    started = now_ms()
    try:
        extractor_output = ExtractorAgent(llm, persona=get_persona(db, "extractor")).extract(context)
        updated_character_ids, added_event_ids = apply_extractor_output(db, chapter, extractor_output)
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            output_data=extractor_output,
            started_at=started,
            **llm_usage_kwargs(llm),
        )
        db.commit()
    except (LLMError, AppError, ValueError) as exc:
        db.rollback()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            started_at=started,
            error=str(exc),
            **llm_usage_kwargs(llm),
        )
        db.commit()
        if isinstance(exc, AppError):
            raise
        raise i18n_upstream(
            "llm_generic",
            retryable=getattr(exc, "retryable", False),
            detail=str(exc),
        ) from exc
    db.refresh(chapter)
    return {
        "chapter": ChapterRead.model_validate(chapter),
        "updated_character_ids": updated_character_ids,
        "added_event_ids": added_event_ids,
    }


@router.post("/chapters/{chapter_id}/import")
def import_chapter(
    chapter_id: str,
    payload: ChapterImportRequest,
    db: Session = Depends(get_db),
    # M-1: import path runs ExtractorAgent (when run_extractor=true) on the
    # imported draft, so it routes to the extractor key just like /finalize.
    llm: LLMClient = Depends(get_extractor_llm_client),
) -> dict[str, object]:
    """Import user-authored chapter text and (optionally) run Extractor on it.

    Mirrors the response envelope of ``POST /chapters/{id}/finalize`` so the
    frontend can treat it as a finalize-equivalent transition. Pre-condition:
    chapter must not already be ``finalized`` (409 otherwise).
    """
    chapter = _get_chapter(db, chapter_id)
    # Plan §5.A.4 white-list: any non-finalized state EXCEPT 'writing'.
    # 'writing' is deliberately excluded — importing mid-stream would race the
    # SSE writer worker, which would later flip status back to draft_ready and
    # overwrite the imported draft_text. Users must cancel or finish the
    # stream first. See A-1 reviewer report.
    ensure_chapter_status(
        chapter,
        {"draft", "prompt_ready", "draft_ready"},
        "import",
    )
    book = _get_book(db, chapter.book_id)

    # Always write the user's draft + mark source. title/summary only if provided.
    chapter.draft_text = payload.draft_text
    if payload.title is not None:
        chapter.title = payload.title
    if payload.summary is not None:
        chapter.summary = payload.summary
    chapter.source = "imported"
    chapter.updated_at = utc_now()

    if not payload.run_extractor:
        # Skip Extractor — finalize directly. If caller supplied no summary,
        # leave whatever was already there (may be None). Extractor path below
        # is the canonical way to fill summary + timeline + live_fields.
        chapter.status = "finalized"
        chapter.updated_at = utc_now()
        db.commit()
        db.refresh(chapter)
        return {
            "chapter": ChapterRead.model_validate(chapter),
            "updated_character_ids": [],
            "added_event_ids": [],
        }

    # run_extractor=True — v1.3.1 (KK) P4: two-phase commit.
    #
    # Pre-P4 this branch only `db.flush()`'d before running the Extractor, so
    # a failure below would `db.rollback()` the flushed-but-uncommitted
    # draft_text/title/source/status="finalized" changes ABOVE right along
    # with the extractor's own writes — losing the user's imported text on a
    # transient LLM failure. That contradicted the "import lands the draft
    # first, extraction is best-effort on top" intent (mirrors /finalize's
    # sibling behavior only superficially — /finalize's chapter was already
    # persisted as draft_ready in an earlier request).
    #
    # Fix: commit phase one (draft_text/title/summary/source/finalized) unconditionally
    # first — same "commit now" shape as the `run_extractor=false` branch above
    # — so the import itself can never be undone by an extractor hiccup. Phase
    # two (extractor + apply + log) runs in its own transaction; on failure we
    # only roll back the extractor's own uncommitted writes, never phase one.
    chapter.status = "finalized"
    chapter.updated_at = utc_now()
    db.commit()
    db.refresh(chapter)

    context = build_extractor_context(db, book, chapter)
    started = now_ms()
    try:
        extractor_output = ExtractorAgent(llm, persona=get_persona(db, "extractor")).extract(context)
        updated_character_ids, added_event_ids = apply_extractor_output(db, chapter, extractor_output)
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            output_data=extractor_output,
            started_at=started,
            **llm_usage_kwargs(llm),
        )
        db.commit()
    except (LLMError, AppError, ValueError) as exc:
        # Only the extractor's own (uncommitted) writes roll back here — the
        # chapter's finalized draft_text/title/source from phase one was
        # already committed above and is untouched by this rollback.
        db.rollback()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="extractor",
            input_data=context,
            started_at=started,
            error=str(exc),
            **llm_usage_kwargs(llm),
        )
        db.commit()
        if isinstance(exc, AppError):
            raise
        raise i18n_upstream(
            "llm_generic",
            retryable=getattr(exc, "retryable", False),
            detail=str(exc),
        ) from exc
    db.refresh(chapter)
    return {
        "chapter": ChapterRead.model_validate(chapter),
        "updated_character_ids": updated_character_ids,
        "added_event_ids": added_event_ids,
    }


@router.post("/chapters/{chapter_id}/reopen", response_model=ChapterRead)
def reopen_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = _get_chapter(db, chapter_id)
    ensure_chapter_status(chapter, {"finalized"}, "reopen")
    db.execute(delete(TimelineEvent).where(TimelineEvent.chapter_id == chapter.id))
    chapter.summary = None
    chapter.status = "draft_ready"
    chapter.updated_at = utc_now()
    db.commit()
    db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


@router.get("/chapters/{chapter_id}/export")
def export_chapter(
    chapter_id: str,
    format: ExportFormat = Query(default="markdown"),
    db: Session = Depends(get_db),
) -> Response:
    """Export a single chapter as Markdown or plain text.

    PROJECT_PLAN §5.F. Mirrors the book-level endpoint but produces a
    standalone file — useful for sharing one chapter without dumping
    the entire book. No ``include_drafts`` toggle here: explicitly
    exporting one chapter implies the user wants it regardless of
    state.

    Filename is ``第N章·title.{md,txt}`` (URL-encoded for non-ASCII).
    """
    chapter = _get_chapter(db, chapter_id)
    book = _get_book(db, chapter.book_id)

    if format == "markdown":
        body = export_chapter_markdown(chapter, book)
        media_type = "text/markdown; charset=utf-8"
        extension = "md"
    else:
        body = export_chapter_txt(chapter, book)
        media_type = "text/plain; charset=utf-8"
        extension = "txt"

    title = (chapter.title or "").strip()
    base = f"第{chapter.index}章·{title}" if title else f"第{chapter.index}章"
    filename = build_filename(base, extension)
    return Response(
        content=body,
        media_type=media_type,
        headers={"Content-Disposition": build_content_disposition(filename)},
    )


@router.post("/chapters/{chapter_id}/admin_reset", response_model=ChapterRead)
def admin_reset_chapter(
    chapter_id: str,
    payload: ChapterAdminResetRequest = Body(default_factory=ChapterAdminResetRequest),
    db: Session = Depends(get_db),
) -> ChapterRead:
    """Force-reset a stuck chapter to a normal editable state.

    v0.7 §5.P.1 E. Used when a chapter is stranded in ``writing`` (SSE
    crash, client died, server restart mid-stream) and no normal path
    can recover it. Allowed from *any* current status — that's the
    whole point of an escape hatch — but the target is constrained
    by ``ChapterAdminResetRequest`` to a safe re-editable state. The
    chapter's ``draft_text`` / ``structured_prompt`` are deliberately
    preserved so the user keeps whatever half-finished work was there.

    An ``agent_logs`` row is written so the rescue is auditable.
    """
    chapter = _get_chapter(db, chapter_id)
    # v1.3.2 (LL) P1 (🟡4): the escape hatch takes priority over any live write
    # worker. Cancel it first and wait (bounded) for it to reach a terminal
    # commit, so its final DB write can't clobber the reset we're about to make
    # authoritative. Then re-read the row so ``from_status`` reflects the
    # worker's settled state.
    live = write_registry.get_live(chapter_id)
    if live is not None:
        live.cancel_and_wait(CANCEL_WAIT_SECONDS)
        db.refresh(chapter)
    from_status = chapter.status
    to_status = payload.target_status
    # Idempotent: if the chapter is already in the requested state, return
    # without touching updated_at or writing a new agent_log row. Otherwise
    # a user double-clicking the "重置" button (or the UI retrying on a
    # flaky network) would spam the audit log with no-op rescues.
    if from_status == to_status:
        return ChapterRead.model_validate(chapter)
    chapter.status = to_status
    chapter.updated_at = utc_now()
    log_agent_call(
        db,
        chapter_id=chapter.id,
        agent_name="admin_reset",
        input_data={"from_status": from_status, "to_status": to_status},
        output_data=None,
        started_at=None,
    )
    db.commit()
    db.refresh(chapter)
    return ChapterRead.model_validate(chapter)


def _sse(event: str, data: dict[str, object]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False, default=str)}\n\n"


def _ensure_book(db: Session, book_id: str) -> None:
    if db.get(Book, book_id) is None:
        raise i18n_not_found("book")


def _get_book(db: Session, book_id: str) -> Book:
    book = db.get(Book, book_id)
    if book is None:
        raise i18n_not_found("book")
    return book


def _get_chapter(db: Session, chapter_id: str) -> Chapter:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise i18n_not_found("chapter")
    return chapter
