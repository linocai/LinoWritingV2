from __future__ import annotations

import json
from collections.abc import Iterator
from queue import Empty, Queue
from threading import Event, Thread
from typing import Literal

from fastapi import APIRouter, Body, Depends, Query, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.agents.extractor import ExtractorAgent
from app.agents.prompt_expander import PromptExpanderAgent
from app.agents.writer import WriterAgent
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
from app.services.agent_logging import log_agent_call, now_ms
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

# v0.7 §5.F — same Literal trick as in books.py.
ExportFormat = Literal["markdown", "txt"]

router = APIRouter(tags=["chapters"])
KEEPALIVE_SECONDS = 15

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
    chapter = _get_chapter(db, chapter_id)
    ensure_chapter_status(chapter, {"prompt_ready", "draft_ready"}, "write")
    book = _get_book(db, chapter.book_id)
    context = build_writer_context(db, book, chapter)
    # Resolve the Writer persona (DB, App-editable) up front — the streaming
    # producer runs on a daemon thread and must not touch the request session.
    writer_persona = get_persona(db, "writer")
    previous_status = chapter.status
    chapter.status = "writing"
    chapter.updated_at = utc_now()
    db.commit()

    return StreamingResponse(
        _write_stream(db, chapter.id, previous_status, context, llm, writer_persona),
        media_type="text/event-stream",
    )


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

    # run_extractor=True — reuse the same path finalize uses.
    # Flush so context_pack sees the freshly-written draft_text.
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


def _write_stream(
    db: Session,
    chapter_id: str,
    previous_status: str,
    context: dict[str, object],
    llm: LLMClient,
    writer_persona: str,
) -> Iterator[str]:
    started = now_ms()
    parts: list[str] = []
    chars = 0
    restored_or_completed = False
    # Shared cancel signal. Set in the finally block when the generator is
    # torn down (normal completion, error, or client disconnect). The
    # producer thread checks it before each queue.put, and the LLM client
    # checks it inside its iter_lines() loop, so cancellation propagates
    # all the way down to closing the upstream socket. Without this,
    # client-disconnect would leave the daemon thread running and keep
    # pulling (billable) tokens until the model finished naturally.
    # See §5.P.1 D.
    cancel_event = Event()
    try:
        yield _sse("started", {"chapter_id": chapter_id})
        queue: Queue[tuple[str, object]] = Queue()

        def produce_tokens() -> None:
            try:
                for token in WriterAgent(llm, persona=writer_persona).stream(context, cancel_event=cancel_event):
                    if cancel_event.is_set():
                        # Defensive: even if the LLM client somehow yielded
                        # one more token after we signalled cancel, don't
                        # bother enqueueing it — the consumer is gone.
                        break
                    queue.put(("token", token))
                # Only mark done if we weren't cancelled — a cancelled
                # stream is neither "done" nor "error" from the consumer's
                # perspective, the generator is already being torn down.
                if not cancel_event.is_set():
                    queue.put(("done", None))
            except Exception as exc:
                if not cancel_event.is_set():
                    queue.put(("error", exc))

        Thread(target=produce_tokens, daemon=True).start()

        while True:
            try:
                event_type, payload = queue.get(timeout=KEEPALIVE_SECONDS)
            except Empty:
                yield ": keepalive\n\n"
                continue
            if event_type == "done":
                break
            if event_type == "error":
                raise payload  # type: ignore[misc]
            token = str(payload)
            parts.append(token)
            chars += len(token)
            yield _sse("token", {"text": token})
            yield _sse("progress", {"chars": chars})
        draft_text = "".join(parts)
        chapter = _get_chapter(db, chapter_id)
        chapter.draft_text = draft_text
        chapter.status = "draft_ready"
        chapter.updated_at = utc_now()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="writer",
            input_data=context,
            output_data=draft_text,
            started_at=started,
        )
        db.commit()
        db.refresh(chapter)
        restored_or_completed = True
        yield _sse("done", {"chapter": ChapterRead.model_validate(chapter).model_dump(mode="json")})
    except Exception as exc:
        db.rollback()
        chapter = _get_chapter(db, chapter_id)
        chapter.status = previous_status
        chapter.updated_at = utc_now()
        log_agent_call(
            db,
            chapter_id=chapter.id,
            agent_name="writer",
            input_data=context,
            output_data="".join(parts) if parts else None,
            started_at=started,
            error=str(exc),
        )
        db.commit()
        restored_or_completed = True
        # v0.7 §5.N — wrap LLM stream failures with Chinese template so the
        # SSE error payload (which the frontend surfaces directly in the
        # Toast) is reader-friendly. The original message goes into the
        # template's {detail} slot.
        error = i18n_upstream(
            "llm_generic",
            retryable=getattr(exc, "retryable", True),
            detail=str(exc),
        )
        yield _sse(
            "error",
            {
                "error": {
                    "kind": error.kind,
                    "message": error.message,
                    "retryable": error.retryable,
                    "details": error.details,
                }
            },
        )
    finally:
        # Always signal cancel on the way out so the producer thread (and,
        # transitively, the LLM client's iter_lines() loop) wakes up and
        # exits. This is the critical bit for client-disconnect: FastAPI
        # closes the generator, we hit this finally, the daemon thread
        # sees the event and bails. Closing the httpx response is what
        # actually tells the upstream to stop generating tokens.
        cancel_event.set()
        if not restored_or_completed:
            db.rollback()
            try:
                chapter = _get_chapter(db, chapter_id)
                if chapter.status == "writing":
                    chapter.status = previous_status
                    chapter.updated_at = utc_now()
                    log_agent_call(
                        db,
                        chapter_id=chapter.id,
                        agent_name="writer",
                        input_data=context,
                        output_data="".join(parts) if parts else None,
                        started_at=started,
                        error="stream cancelled before completion",
                    )
                    db.commit()
            except Exception:
                db.rollback()


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
