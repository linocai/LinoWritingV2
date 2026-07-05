"""Tests for v1.2.0 (HH) P7 — thinking-model support (SSE `thinking` frames).

Contract (PROJECT_PLAN.md §4.0 / §4.1 P7):
  - `complete_stream` yields typed `StreamChunk(kind, text)` — `"token"` for
    final-answer content, `"thinking"` for chain-of-thought/reasoning deltas.
  - `_write_stream` forwards `thinking` chunks as `event: thinking` SSE
    frames (`{"text": ...}`), and they must NEVER land in `parts`/`chars`/
    `draft_text` — only `token` chunks do.
  - A model that only ever emits `content` (no `reasoning_content`) must
    produce zero `thinking` frames — pure regression, unaffected behaviour.
"""
from __future__ import annotations

from collections.abc import Iterator
from typing import Any

from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.routers.chapters import _write_stream
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
    """Emits interleaved thinking + token chunks, mirroring a reasoning
    model that thinks first then writes the final answer."""

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        yield StreamChunk(kind="thinking", text="让我想想这一章该怎么写。")
        yield StreamChunk(kind="thinking", text="主角应该先发现线索。")
        yield StreamChunk(kind="token", text="清晨的雾")
        yield StreamChunk(kind="token", text="还没散。")


class _PureTokenLLM(MockLLMClient):
    """A model that never emits reasoning_content — regression baseline."""

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[StreamChunk]:
        yield StreamChunk(kind="token", text="没有思考过程的")
        yield StreamChunk(kind="token", text="普通模型。")


def test_thinking_chunks_forwarded_as_sse_frames_and_excluded_from_draft(db_session):
    chapter = _make_chapter(db_session)

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_ThinkingThenTokenLLM(),
        writer_persona="测试 Writer 人格",
    )
    events = list(gen)

    thinking_events = [e for e in events if e.startswith("event: thinking")]
    assert len(thinking_events) == 2
    assert "让我想想这一章该怎么写。" in thinking_events[0]
    assert "主角应该先发现线索。" in thinking_events[1]

    # done event must still fire, and draft_text must contain ONLY the
    # token chunks — thinking text must never leak into the saved draft.
    assert any(e.startswith("event: done") for e in events)
    db_session.refresh(chapter)
    assert chapter.draft_text == "清晨的雾还没散。"
    assert "想想" not in chapter.draft_text
    assert "线索" not in chapter.draft_text
    assert chapter.status == "draft_ready"


def test_thinking_chunks_not_counted_toward_progress_chars(db_session):
    """`progress` events report `chars` — must only count token text, never
    thinking text (otherwise the frontend word-count display would include
    reasoning tokens the user never sees as prose)."""
    chapter = _make_chapter(db_session)

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_ThinkingThenTokenLLM(),
        writer_persona="测试 Writer 人格",
    )
    events = list(gen)

    progress_events = [e for e in events if e.startswith("event: progress")]
    # Two token chunks: "清晨的雾" (4 chars) then "清晨的雾还没散。" (8 chars).
    assert '"chars": 4' in progress_events[0]
    assert '"chars": 8' in progress_events[1]


def test_pure_content_model_emits_zero_thinking_frames(db_session):
    """Regression: a model with no reasoning_content must produce exactly
    the pre-P7 behaviour — only token/progress/done, no thinking frames."""
    chapter = _make_chapter(db_session)

    gen = _write_stream(
        db_session,
        chapter.id,
        previous_status="prompt_ready",
        context={},
        llm=_PureTokenLLM(),
        writer_persona="测试 Writer 人格",
    )
    events = list(gen)

    thinking_events = [e for e in events if e.startswith("event: thinking")]
    assert thinking_events == []

    db_session.refresh(chapter)
    assert chapter.draft_text == "没有思考过程的普通模型。"
    assert chapter.status == "draft_ready"


def test_openai_compatible_forwards_reasoning_content_as_thinking_chunk():
    """Unit-level check on `OpenAICompatibleClient._stream`'s delta parsing:
    a chunk carrying `reasoning_content` yields a `thinking` StreamChunk,
    separate from any `content` in the same or a later chunk."""
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
