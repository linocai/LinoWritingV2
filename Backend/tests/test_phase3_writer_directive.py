from __future__ import annotations

# v1.0.0 EE Phase 3 (archive/v1.0.0_plan.md §7-Phase 3) gates:
#   A. Writer 接 chapter_directive — the Expander's 200-300 字 directive actually
#      enters the Writer's user message, surfaced as its OWN top-level line
#      (方向), distinct from the characters / timelines knowledge line (知识).
#      P1 红线 "两条线分明": the directive does NOT replace card injection.
#   B. 降级 — when the directive is missing (old / un-expanded chapter), the
#      Writer still runs (no raise) and the cards/timelines line is unaffected.
#   C. Writer 人格/边界 — the §8.2 boundary ("执行 directive / 连贯优先 / 不越权
#      推进 directive 之外的剧情 / 角色卡是水库") is in the DB persona, and the
#      directive-handling + two-line rule is in the fixed operational rules.
#   D. 档案员 append-only — extracting chapter N never wipes chapter N-1's
#      already-written timeline; re-extracting chapter N is idempotent for its
#      OWN events only. §8.3 extractor boundary is in the DB persona.

import json
from typing import Any

from app.agents.writer import WriterAgent
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.services.context_pack import build_writer_context
from app.services.personas import DEFAULT_PERSONAS
from tests.conftest import MockLLMClient


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


class _CapturingStreamLLM:
    """Captures the user/system message Writer hands to the LLM client."""

    def __init__(self) -> None:
        self.last_user: str | None = None
        self.last_system: str | None = None

    def complete(self, **kwargs: Any) -> str:  # pragma: no cover - unused
        return ""

    def complete_json(self, **kwargs: Any) -> dict[str, Any]:  # pragma: no cover
        return {}

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):
        self.last_system = system
        self.last_user = user
        if False:  # pragma: no cover - generator that yields nothing
            yield ""


# A realistic 本章创作指令 (steering prose), carrying NO card / timeline content.
_DIRECTIVE = (
    "本章把林夕推到第一个真正的抉择口：他必须决定独自追下去还是回城求援。"
    "张力压在「信任」上，请把犹疑写进停顿与回头，落点收在他做出选择的瞬间。"
)


# --------------------------------------------------------------------------
# Gate A — chapter_directive enters the Writer, as its own line, beside cards
# --------------------------------------------------------------------------


def test_writer_context_surfaces_chapter_directive_as_top_level_line(db_session):
    """build_writer_context lifts chapter_directive out of structured_prompt to a
    top-level key — its own 方向 line, distinct from the 知识 (cards/timelines)."""
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id,
        name="林夕",
        role="主角",
        frozen_fields={"core_traits": "谨慎"},
        live_fields={"current_status": "调查"},
    )
    db_session.add(character)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="找线索",
        status="prompt_ready",
        structured_prompt={
            "chapter_goal": "推进",
            "characters_involved": [character.id],
            "chapter_directive": _DIRECTIVE,
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    # 方向 line present as its own top-level key.
    assert ctx["chapter_directive"] == _DIRECTIVE
    # 知识 line still present and independent — the card was NOT replaced by the
    # directive; both lines coexist (P1 两条线分明).
    assert [c["id"] for c in ctx["characters"]] == [character.id]
    assert ctx["characters"][0]["frozen_fields"] == {"core_traits": "谨慎"}


def test_writer_user_message_carries_chapter_directive(db_session):
    """The directive actually reaches the LLM's user message via the Writer."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id, name="林夕", role="主角", frozen_fields={"core_traits": "谨慎"}, live_fields={}
    )
    db_session.add(character)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="x",
        status="prompt_ready",
        structured_prompt={
            "chapter_goal": "推进",
            "characters_involved": [character.id],
            "chapter_directive": _DIRECTIVE,
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    llm = _CapturingStreamLLM()
    list(WriterAgent(llm).stream(ctx))
    assert llm.last_user is not None
    # The directive text rides in the user message...
    assert _DIRECTIVE in llm.last_user
    # ...under its own JSON key (top-level 方向 line, not buried as a nested
    # structured_prompt sub-field only).
    payload = json.loads(llm.last_user.split("\n\n")[0])
    assert payload["chapter_directive"] == _DIRECTIVE
    # 知识 line still independently present — directive did NOT replace cards.
    assert payload["characters"][0]["id"] == character.id


def test_directive_is_separate_line_from_card_knowledge(db_session):
    """P1 红线 assertion: the directive is steering only; the character's card
    knowledge reaches the Writer on its OWN line, NOT through the directive."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id,
        name="林夕",
        role="主角",
        frozen_fields={"core_traits": "谨慎", "background": "退役追踪员"},
        live_fields={"current_status": "调查失踪案"},
        author_notes={"motivation": "为妹妹复仇"},
    )
    db_session.add(character)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="x",
        status="prompt_ready",
        structured_prompt={
            "chapter_goal": "推进",
            "characters_involved": [character.id],
            "chapter_directive": _DIRECTIVE,  # carries NO card content
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    # The directive line carries none of the card knowledge — that all lives on
    # the characters line. The two are distinct keys in the context.
    assert "current_status" not in ctx["chapter_directive"]
    assert "为妹妹复仇" not in ctx["chapter_directive"]
    assert "退役追踪员" not in ctx["chapter_directive"]
    # Knowledge IS delivered, just on the separate characters line.
    card = ctx["characters"][0]
    assert card["live_fields"]["current_status"] == "调查失踪案"
    assert card["frozen_fields"]["background"] == "退役追踪员"
    assert card["author_notes"]["motivation"] == "为妹妹复仇"


# --------------------------------------------------------------------------
# Gate B — graceful degradation when the directive is absent
# --------------------------------------------------------------------------


def test_writer_context_directive_none_for_old_chapter(db_session):
    """Old / un-expanded chapter: no chapter_directive in structured_prompt →
    None, never a raise; the cards line is unaffected."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id, name="林夕", role="主角", frozen_fields={"core_traits": "谨慎"}, live_fields={}
    )
    db_session.add(character)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="x",
        status="prompt_ready",
        # No chapter_directive key at all (pre-P3 / un-expanded chapter).
        structured_prompt={"chapter_goal": "推进", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert ctx["chapter_directive"] is None
    # Cards line still intact — degradation didn't drop knowledge.
    assert [c["id"] for c in ctx["characters"]] == [character.id]


def test_writer_context_directive_none_when_blank(db_session):
    """A whitespace-only directive collapses to None (treated as absent)."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="x",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": [], "chapter_directive": "   \n  "},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert ctx["chapter_directive"] is None


def test_writer_still_streams_without_directive(db_session):
    """Writer must run end-to-end when the directive is missing (降级)."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="x",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": []},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    out = "".join(WriterAgent(MockLLMClient()).stream(ctx))
    # MockLLMClient yields two prose fragments — proves the stream ran.
    assert out  # non-empty → did not raise / stall


# --------------------------------------------------------------------------
# Gate C — Writer persona (§8.2) + operational rules teach directive handling
# --------------------------------------------------------------------------


def test_writer_persona_carries_boundary_segment():
    """§8.2 boundary must live in the DB-editable persona (not the rules)."""
    persona = DEFAULT_PERSONAS["writer"]
    assert "执行 chapter_directive" in persona
    assert "不越权推进 directive 之外的剧情" in persona
    assert "连贯优先" in persona
    assert "水库" in persona  # 角色卡是水库不是清单


def test_writer_operational_rules_teach_two_line_separation():
    """The directive-handling + 两条线分明 rule rides in the fixed operational
    rules, and the graceful-degrade instruction is present."""
    rules = WriterAgent.OPERATIONAL_RULES
    assert "chapter_directive" in rules
    assert "方向盘" in rules
    assert "两条线" in rules  # 方向 vs 知识
    assert "不越权推进 directive 之外的剧情" in rules
    # Degrade instruction: behave when the directive is absent.
    assert "缺失" in rules or "null" in rules


def test_writer_default_system_prompt_composes_persona_then_rules():
    """The composed default system prompt carries both the §8.2 persona and the
    directive operational rule (regression surface for keyword tests)."""
    sp = WriterAgent.system_prompt
    assert sp.startswith(DEFAULT_PERSONAS["writer"])
    assert "chapter_directive" in sp
    assert "只输出正文纯文本" in sp  # existing mechanics survive


# --------------------------------------------------------------------------
# Gate D — extractor append-only across chapters + §8.3 persona
# --------------------------------------------------------------------------


class _PerCallExtractorLLM(MockLLMClient):
    """Extractor mock that stamps each chapter's timeline event with the
    chapter's draft_text, so events from different chapters are distinguishable
    — lets us prove chapter N's extraction never wipes chapter N-1's events."""

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        context = json.loads(user)
        if "all_characters" in context:  # expander path — keep default
            return super().complete_json(system=system, user=user, schema=schema, **kwargs)
        character = context["characters"][0]
        draft = context["chapter"]["draft_text"]
        return {
            "summary": f"本章摘要：{draft[:20]}",
            "timeline_events": [
                {
                    "character_id": character["id"],
                    "event_type": "action",
                    "event_text": f"事件@{draft}",
                }
            ],
            "character_updates": [
                {
                    "character_id": character["id"],
                    "live_fields_patch": {"current_status": draft},
                }
            ],
        }


def _seed_book_character(client, auth_headers) -> tuple[dict, dict]:
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "长夜", "cover_color": "#111111"},
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎"},
            "live_fields": {"current_status": "调查"},
        },
    ).json()
    return book, character


def _new_chapter(client, auth_headers, book_id: str, prompt: str) -> dict:
    resp = client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": prompt},
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _import_finalized(client, auth_headers, chapter_id: str, draft: str) -> None:
    resp = client.post(
        f"/api/v1/chapters/{chapter_id}/import",
        headers=auth_headers,
        json={"draft_text": draft, "run_extractor": False},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["chapter"]["status"] == "finalized"


def test_extract_is_append_only_across_chapters(client, auth_headers):
    """P2 红线: extracting chapter 2 does NOT wipe chapter 1's timeline; the
    memory accumulates (append-only). Re-extracting a chapter only replaces its
    OWN events (idempotent per-chapter), never another chapter's."""
    from app.llm.base import get_extractor_llm_client
    from app.main import app

    app.dependency_overrides[get_extractor_llm_client] = lambda: _PerCallExtractorLLM()
    try:
        book, character = _seed_book_character(client, auth_headers)

        ch1 = _new_chapter(client, auth_headers, book["id"], "第一章")
        _import_finalized(client, auth_headers, ch1["id"], "第一章正文")
        r1 = client.post(f"/api/v1/chapters/{ch1['id']}/extract", headers=auth_headers)
        assert r1.status_code == 200, r1.text

        ch2 = _new_chapter(client, auth_headers, book["id"], "第二章")
        _import_finalized(client, auth_headers, ch2["id"], "第二章正文")
        r2 = client.post(f"/api/v1/chapters/{ch2['id']}/extract", headers=auth_headers)
        assert r2.status_code == 200, r2.text

        # Both chapters' events coexist — chapter 2's extraction did NOT delete
        # chapter 1's. Timeline is append-only across chapters.
        timeline = client.get(
            f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
        ).json()["items"]
        texts = {e["event_text"] for e in timeline}
        assert "事件@第一章正文" in texts
        assert "事件@第二章正文" in texts
        assert len(timeline) == 2

        # Re-extract chapter 1 — its own event is replaced (idempotent), but
        # chapter 2's event is left untouched (still there).
        r1b = client.post(f"/api/v1/chapters/{ch1['id']}/extract", headers=auth_headers)
        assert r1b.status_code == 200, r1b.text
        timeline2 = client.get(
            f"/api/v1/characters/{character['id']}/timeline", headers=auth_headers
        ).json()["items"]
        texts2 = {e["event_text"] for e in timeline2}
        assert "事件@第一章正文" in texts2  # re-created, not duplicated
        assert "事件@第二章正文" in texts2  # chapter 2 survived
        assert len(timeline2) == 2  # no duplication of chapter 1's event
    finally:
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()


def test_extractor_persona_carries_append_only_boundary():
    """§8.3 boundary must live in the DB-editable extractor persona."""
    persona = DEFAULT_PERSONAS["extractor"]
    assert "append-only" in persona
    assert "只记已发生的事实" in persona
    assert "不演绎" in persona
    assert "不改 frozen_fields" in persona
    assert "author_notes" in persona  # 不读/不动 author_notes
