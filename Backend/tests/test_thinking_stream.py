"""Thinking-model support (SSE ``thinking`` frames), adapted for v1.3.2 (LL) P1
writing-as-a-job.

Contract:
  - ``complete_stream`` yields typed ``StreamChunk`` — ``"token"`` for final
    prose, ``"thinking"`` for chain-of-thought.
  - The **worker** never lets ``thinking`` text into ``buffer`` / ``chars`` /
    ``draft_text`` — only ``token`` chunks accumulate.
  - The **tail** (``_stream_job``) forwards a transient ``thinking`` frame when
    the job's thinking indicator advances (coalescing under contention — it's a
    process hint, not a replayable log; ``WriteJob`` deliberately holds no
    thinking buffer, plan §4 🟡3①).
"""
from __future__ import annotations

import threading
import time
from collections.abc import Iterator
from typing import Any

from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.routers.chapters import _stream_job
from app.services.write_jobs import WriteJob, _mark_terminal, write_registry
from tests.conftest import MockLLMClient


def _make_chapter(db_session, *, status: str = "writing") -> Chapter:
    book = Book(title="P7 思考流测试", cover_color="#000000")
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
    )
    db_session.add(chapter)
    db_session.commit()
    db_session.refresh(chapter)
    return chapter


class _ThinkingThenTokenLLM(MockLLMClient):
    """Emits interleaved thinking + token chunks, mirroring a reasoning model."""

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        yield StreamChunk(kind="thinking", text="让我想想这一章该怎么写。")
        yield StreamChunk(kind="thinking", text="主角应该先发现线索。")
        yield StreamChunk(kind="token", text="清晨的雾")
        yield StreamChunk(kind="token", text="还没散。")


class _PureTokenLLM(MockLLMClient):
    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        yield StreamChunk(kind="token", text="没有思考过程的")
        yield StreamChunk(kind="token", text="普通模型。")


def _run_worker(db_session, chapter, llm) -> WriteJob:
    job = write_registry.reserve(
        chapter.id, previous_status="prompt_ready", context={}, llm=llm, writer_persona="测试 Writer 人格"
    )
    write_registry.launch(job, db_session.get_bind())
    job.thread.join(timeout=5)
    return job


def test_worker_excludes_thinking_from_draft_and_chars(db_session):
    chapter = _make_chapter(db_session)
    job = _run_worker(db_session, chapter, _ThinkingThenTokenLLM())

    assert job.phase == "done"
    # Only token text accumulated into buffer/chars.
    assert "".join(job.buffer) == "清晨的雾还没散。"
    assert job.chars == len("清晨的雾还没散。")
    # thinking text must never leak into the saved draft.
    db_session.refresh(chapter)
    assert chapter.draft_text == "清晨的雾还没散。"
    assert "想想" not in (chapter.draft_text or "")
    assert "线索" not in (chapter.draft_text or "")
    assert chapter.status == "draft_ready"


def test_pure_content_model_never_bumps_thinking(db_session):
    chapter = _make_chapter(db_session)
    job = _run_worker(db_session, chapter, _PureTokenLLM())
    assert job.phase == "done"
    assert job.thinking_epoch == 0  # no thinking chunks → indicator never moved
    db_session.refresh(chapter)
    assert chapter.draft_text == "没有思考过程的普通模型。"
    assert chapter.status == "draft_ready"


def test_stream_job_forwards_thinking_frame_live():
    """The tail forwards a transient ``thinking`` frame when the indicator
    advances, kept separate from ``token``/``progress``."""
    job = WriteJob("cid", "prompt_ready", {}, MockLLMClient(), "persona")

    def feeder():
        time.sleep(0.02)
        with job.condition:
            job.latest_thinking = "模型正在思考…"
            job.thinking_epoch += 1
            job.condition.notify_all()
        time.sleep(0.01)
        with job.condition:
            job.buffer.append("正文")
            job.chars += len("正文")
            job.condition.notify_all()
        time.sleep(0.01)
        _mark_terminal(job, phase="done", done_chapter={"id": "cid", "status": "draft_ready"})

    threading.Thread(target=feeder, daemon=True).start()
    frames = "".join(_stream_job(job, send_started=True, send_snapshot=False))

    assert "event: thinking" in frames
    assert "模型正在思考" in frames
    assert "event: token" in frames
    assert "event: done" in frames


def test_openai_compatible_forwards_reasoning_content_as_thinking_chunk():
    """Unit-level check on ``OpenAICompatibleClient._stream``'s delta parsing:
    a chunk carrying ``reasoning_content`` yields a ``thinking`` StreamChunk,
    separate from any ``content`` in the same or a later chunk."""
    from unittest.mock import patch

    from app.llm.openai_compatible import OpenAICompatibleClient
    from app.models.provider_key import ProviderKey
    from tests.test_sse_cancel import _FakeHttpxStream

    provider_key = ProviderKey(
        id="00000000-0000-0000-0000-000000000003",
        key_label="test-p7",
        provider_hint="custom",
        base_url="https://example.test/v1",
        api_key="sk-test-p7",
        model_name="deepseek-reasoner",
    )
    client = OpenAICompatibleClient(provider_key)
    fake = _FakeHttpxStream(
        [
            'data: {"choices":[{"delta":{"reasoning_content":"思考中…"}}]}',
            'data: {"choices":[{"delta":{"content":"正文开始"}}]}',
            "data: [DONE]",
        ]
    )

    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        chunks = list(client.complete_stream(system="s", user="u"))

    assert len(chunks) == 2
    assert chunks[0].kind == "thinking"
    assert chunks[0].text == "思考中…"
    assert chunks[1].kind == "token"
    assert chunks[1].text == "正文开始"
