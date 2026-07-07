"""v1.2.0 (HH) P5 conservative partial-draft policy — now owned by the
writing-as-a-job worker (v1.3.2 LL P1). The policy function
``write_jobs._save_partial_draft`` moved out of ``chapters._write_stream`` (which
no longer exists) but its contract is unchanged:

  - previous_status == "prompt_ready" (nothing to lose) + non-empty parts
    → save draft_text, flip to draft_ready.
  - previous_status == "draft_ready" (a complete earlier draft already exists)
    → never overwrite; the half-finished regenerate is logged only.
  - parts empty → no draft_text write, status restored as before.
  - any other previous_status → restore it, log only.

These drive the pure function directly (deterministic, no threads). The
end-to-end worker paths that *call* it (cancel / upstream-error) are covered in
``test_write_jobs.py``.
"""
from __future__ import annotations

from app.models.agent_log import AgentLog
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.services.agent_logging import now_ms
from app.services.write_jobs import _save_partial_draft


def _make_chapter(db_session, *, status: str, draft_text: str | None = None) -> Chapter:
    book = Book(title="P5 落稿测试", cover_color="#000000")
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


def _latest_log(db_session, chapter_id: str) -> AgentLog | None:
    return (
        db_session.query(AgentLog)
        .filter(AgentLog.chapter_id == chapter_id)
        .order_by(AgentLog.created_at.desc())
        .first()
    )


def test_prompt_ready_with_parts_saves_partial_as_draft_ready(db_session):
    chapter = _make_chapter(db_session, status="writing")
    _save_partial_draft(
        db_session,
        chapter=chapter,
        previous_status="prompt_ready",
        parts=["清", "晨", "的", "雾"],
        context={},
        started=now_ms(),
        error="stream cancelled by user",
    )
    db_session.commit()
    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "清晨的雾"
    log = _latest_log(db_session, chapter.id)
    assert log is not None and log.error is not None
    assert log.output_preview == "清晨的雾"


def test_draft_ready_never_overwrites_existing_draft(db_session):
    original = "已经完成的完整旧稿。"
    chapter = _make_chapter(db_session, status="writing", draft_text=original)
    _save_partial_draft(
        db_session,
        chapter=chapter,
        previous_status="draft_ready",
        parts=["半", "截", "新", "稿"],
        context={},
        started=now_ms(),
        error="上游连接被重置",
    )
    db_session.commit()
    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == original  # untouched
    log = _latest_log(db_session, chapter.id)
    assert log is not None and log.error is not None
    # The half-finished new text lives only in the audit log.
    assert log.output_preview == "半截新稿"


def test_empty_parts_restores_previous_status_no_draft_write(db_session):
    chapter = _make_chapter(db_session, status="writing")
    _save_partial_draft(
        db_session,
        chapter=chapter,
        previous_status="prompt_ready",
        parts=[],
        context={},
        started=now_ms(),
        error="stream cancelled before any token",
    )
    db_session.commit()
    db_session.refresh(chapter)
    assert chapter.status == "prompt_ready"
    assert chapter.draft_text is None


def test_other_previous_status_restores_it(db_session):
    chapter = _make_chapter(db_session, status="writing")
    _save_partial_draft(
        db_session,
        chapter=chapter,
        previous_status="draft",
        parts=["零", "散"],
        context={},
        started=now_ms(),
        error="boom",
    )
    db_session.commit()
    db_session.refresh(chapter)
    # Not prompt_ready → conservative: restore previous, do not write draft_text.
    assert chapter.status == "draft"
    assert chapter.draft_text is None
