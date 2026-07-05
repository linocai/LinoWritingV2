"""Tests for v1.2.0 (HH) P5 — conservative partial-draft save on
disconnect/upstream-error (`_write_stream`'s ``finally``/``except`` branches
share ``_save_partial_draft``).

Both branches previously discarded whatever had been generated so far
(``parts`` only ever reached ``agent_logs`` as a truncated preview, never
``chapter.draft_text``). P5 makes this conservative-but-real:

  - previous_status == "prompt_ready" (nothing to lose) + non-empty parts
    → save draft_text, flip to draft_ready.
  - previous_status == "draft_ready" (a complete earlier draft already
    exists) → never overwrite; the half-finished regenerate is logged only.
  - parts empty → no draft_text write, status restored as before.

Covers both the client-disconnect path (``gen.close()``, mirroring
``test_sse_cancel.py``'s technique since TestClient can't simulate a real
mid-stream disconnect) and the upstream-error path (a mock LLM that raises
mid-generation, driving the ``except`` branch).
"""
from __future__ import annotations

import time
from collections.abc import Iterator
from typing import Any

from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.routers.chapters import _write_stream
from tests.conftest import MockLLMClient
from tests.test_sse_cancel import _ControlledStreamLLM


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


class _RaisingLLM(MockLLMClient):
    """Yields a few tokens then raises — drives the ``except`` branch."""

    def __init__(self, tokens: list[str], error_message: str = "上游连接被重置") -> None:
        self.tokens = tokens
        self.error_message = error_message

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        for token in self.tokens:
            yield StreamChunk(kind="token", text=token)
        raise RuntimeError(self.error_message)


# ---------------------------------------------------------------------------
# finally branch (client disconnect via gen.close())
# ---------------------------------------------------------------------------


def test_disconnect_prompt_ready_saves_partial_draft_as_draft_ready(db_session):
    """No prior draft to lose → disconnect mid-stream saves what we have."""
    chapter = _make_chapter(db_session, status="writing")

    slow_llm = _ControlledStreamLLM(n_tokens=30, per_token_sleep=0.03)
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=slow_llm,
        writer_persona="测试 Writer 人格",
    )

    chunks: list[str] = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 3:  # started + token(t0) + progress(t0)
            break
    gen.close()
    time.sleep(0.4)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "t0"

    # agent_logs must record the disconnect, with the partial text.
    from app.models.agent_log import AgentLog

    log = (
        db_session.query(AgentLog)
        .filter(AgentLog.chapter_id == chapter.id)
        .order_by(AgentLog.created_at.desc())
        .first()
    )
    assert log is not None
    assert log.error is not None
    assert log.output_preview == "t0"


def test_disconnect_draft_ready_does_not_overwrite_existing_draft(db_session):
    """A complete prior draft exists → disconnect during a regenerate must
    never overwrite it, even though partial new text was produced."""
    original = "这是断连前已经完成的旧稿，必须原样保留。"
    chapter = _make_chapter(db_session, status="writing", draft_text=original)

    slow_llm = _ControlledStreamLLM(n_tokens=30, per_token_sleep=0.03)
    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="draft_ready",
        context={},
        llm=slow_llm,
        writer_persona="测试 Writer 人格",
    )

    chunks: list[str] = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 3:
            break
    gen.close()
    time.sleep(0.4)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == original  # untouched

    from app.models.agent_log import AgentLog

    log = (
        db_session.query(AgentLog)
        .filter(AgentLog.chapter_id == chapter.id)
        .order_by(AgentLog.created_at.desc())
        .first()
    )
    assert log is not None
    assert log.error is not None
    # The half-finished new text is only visible in the audit log, never
    # written into chapter.draft_text.
    assert log.output_preview == "t0"


def test_disconnect_with_zero_tokens_generated_restores_previous_status(db_session):
    """Nothing was generated before the disconnect → no draft_text write at
    all, previous_status restored untouched (pre-P5 behaviour preserved)."""
    chapter = _make_chapter(db_session, status="writing")

    class _NeverYieldsLLM(MockLLMClient):
        def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
            time.sleep(1.0)  # Never reached before we close the generator.
            yield StreamChunk(kind="token", text="unused")

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_NeverYieldsLLM(),
        writer_persona="测试 Writer 人格",
    )

    chunks: list[str] = []
    for chunk in gen:
        chunks.append(chunk)
        if len(chunks) >= 1:  # just the "started" event
            break
    gen.close()
    time.sleep(0.2)

    db_session.refresh(chapter)
    assert chapter.status == "prompt_ready"
    assert chapter.draft_text is None


# ---------------------------------------------------------------------------
# except branch (upstream/LLM error mid-generation)
# ---------------------------------------------------------------------------


def test_upstream_error_prompt_ready_saves_partial_draft(db_session):
    chapter = _make_chapter(db_session, status="writing")

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_RaisingLLM(["清", "晨", "的", "雾"]),
        writer_persona="测试 Writer 人格",
    )

    events = list(gen)
    # The error SSE frame must still be sent to the client.
    assert any(e.startswith("event: error") for e in events)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "清晨的雾"


def test_upstream_error_draft_ready_does_not_overwrite_existing_draft(db_session):
    original = "已经完成的完整旧稿。"
    chapter = _make_chapter(db_session, status="writing", draft_text=original)

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="draft_ready",
        context={},
        llm=_RaisingLLM(["半", "截", "新", "稿"]),
        writer_persona="测试 Writer 人格",
    )

    events = list(gen)
    assert any(e.startswith("event: error") for e in events)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == original


def test_upstream_error_zero_tokens_restores_previous_status(db_session):
    chapter = _make_chapter(db_session, status="writing")

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_RaisingLLM([]),  # Raises immediately, no tokens at all.
        writer_persona="测试 Writer 人格",
    )

    events = list(gen)
    assert any(e.startswith("event: error") for e in events)

    db_session.refresh(chapter)
    assert chapter.status == "prompt_ready"
    assert chapter.draft_text is None


# ---------------------------------------------------------------------------
# Regression: normal completion still saves the full draft as draft_ready.
# ---------------------------------------------------------------------------


def test_normal_completion_still_saves_full_draft(db_session):
    chapter = _make_chapter(db_session, status="writing")

    class _CleanLLM(MockLLMClient):
        def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
            for text in ["全", "文", "完", "成"]:
                yield StreamChunk(kind="token", text=text)

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_CleanLLM(),
        writer_persona="测试 Writer 人格",
    )

    events = list(gen)
    assert any(e.startswith("event: done") for e in events)

    db_session.refresh(chapter)
    assert chapter.status == "draft_ready"
    assert chapter.draft_text == "全文完成"
