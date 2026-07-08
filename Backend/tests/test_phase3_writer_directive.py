from __future__ import annotations

# v1.0.0 EE Phase 3 (archive/v1.0.0_plan.md §7-Phase 3) gates, REWRITTEN by
# v1.4.0 (MM) P1 优化师降职 + 作者本章 Bible (see PROJECT_PLAN §4 P1). The
# original gates A/B/C covered the now-deleted ``chapter_directive`` steering
# line; they are rewritten below for the author's own ``user_prompt`` instead
# (ported over, not dropped — same shape of coverage: 主体渲染 / 降级 / 人格
# 教学). Gate D (extractor append-only) is untouched — it never depended on
# the directive at all.
#
#   A. Writer 接 user_prompt Bible — the author's own ``chapter.user_prompt``
#      actually enters the Writer's user message as the PRIMARY content of
#      「# 本章写作任务」, distinct from the characters / timelines knowledge
#      line (知识). The Bible does NOT replace card injection — both lines
#      coexist.
#   B. 降级 — when ``user_prompt`` is missing/blank (should not normally
#      happen — Step 1 requires it — but guards against malformed rows), the
#      Writer still runs (no raise) and the cards/timelines line is
#      unaffected.
#   C. Writer 人格/边界 — the persona's boundary ("请严格根据本章剧情来发挥
#      并写作 / 连贯优先 / 不越权推进 Bible 之外的剧情 / 角色卡是水库") is in
#      the DB persona, and the Bible-handling rule is in the fixed
#      operational rules.
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


# A realistic 本章剧情叙述 (the author's own words) — legitimately mentions a
# character's motivation/status because it IS the author's narrative, not a
# card dump. Distinct from the separate 「# 在场角色」 card-knowledge section.
_USER_PROMPT = (
    "林夕在返程途中意识到自己掌握的线索并不完整，他必须决定是独自追下去还是"
    "回城求援。全章的张力压在「信任」二字上：他既想保护身边的人，又无法判断"
    "谁值得托付。中段安排一次看似偶然的相遇，把上一卷埋下的那枚铜钱伏笔轻轻"
    "拨动一下，但不要揭晓它的来历。落点收在他做出选择的瞬间。"
)


# --------------------------------------------------------------------------
# Gate A — user_prompt (本章节 Bible) enters the Writer, as its own primary
# line, beside cards
# --------------------------------------------------------------------------


def test_writer_context_surfaces_user_prompt_as_top_level_key(db_session):
    """build_writer_context lifts chapter.user_prompt to a top-level ``user_prompt``
    key — its own 剧情 line, distinct from the 知识 (cards/timelines)."""
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
        user_prompt=_USER_PROMPT,
        status="prompt_ready",
        structured_prompt={
            "characters_involved": [character.id],
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    # 剧情 line present as its own top-level key, verbatim.
    assert ctx["user_prompt"] == _USER_PROMPT
    # 知识 line still present and independent — the Bible does NOT replace the
    # card; both lines coexist (P1 两条线，author's plot vs card knowledge).
    assert [c["id"] for c in ctx["characters"]] == [character.id]
    assert ctx["characters"][0]["frozen_fields"] == {"core_traits": "谨慎"}


def test_writer_user_message_carries_user_prompt_as_bible(db_session):
    """The author's own narrative actually reaches the LLM's user message via
    the Writer, labelled as 本章节 Bible / highest authority."""
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
        user_prompt=_USER_PROMPT,
        status="prompt_ready",
        structured_prompt={
            "characters_involved": [character.id],
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    llm = _CapturingStreamLLM()
    list(WriterAgent(llm).stream(ctx))
    assert llm.last_user is not None
    msg = llm.last_user
    # The Bible text rides in the user message, under its own labelled intro
    # inside the「# 本章写作任务」section — as the PRIMARY / first content.
    assert "本章节 Bible" in msg
    assert "情节的最高权威" in msg
    assert _USER_PROMPT in msg
    task_section = msg.split("# 本章写作任务", 1)[1]
    assert task_section.lstrip().startswith("作者本章剧情叙述")
    # No trace of the deleted directive concept.
    assert "本章创作指令" not in msg
    assert "chapter_directive" not in msg
    # 知识 line still independently present — the Bible did NOT replace cards —
    # on its own「# 在场角色」section, naming the character.
    assert "# 在场角色" in msg
    assert character.name in msg


def test_user_prompt_bible_is_separate_line_from_card_knowledge(db_session):
    """P1 红线 assertion: the Bible is the author's own plot narrative; the
    character's card knowledge reaches the Writer on its OWN line — the two
    coexist, neither replaces the other."""
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
        user_prompt=_USER_PROMPT,
        status="prompt_ready",
        structured_prompt={
            "characters_involved": [character.id],
        },
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    # The Bible line is the author's own words — verbatim, untouched — while
    # the card's knowledge (frozen/live/author_notes) lives entirely on the
    # separate characters line, never folded into user_prompt.
    assert ctx["user_prompt"] == _USER_PROMPT
    card = ctx["characters"][0]
    assert card["live_fields"]["current_status"] == "调查失踪案"
    assert card["frozen_fields"]["background"] == "退役追踪员"
    assert card["author_notes"]["motivation"] == "为妹妹复仇"


# --------------------------------------------------------------------------
# Gate B — graceful degradation when user_prompt is missing/blank
# (ported from the old chapter_directive-absent gate — ``user_prompt``
# should always be non-empty in practice per Step 1, but the Writer must not
# raise on a malformed/old row either)
# --------------------------------------------------------------------------


def test_writer_context_user_prompt_blank_for_missing_row_field(db_session):
    """A chapter with no ``user_prompt`` at all (``None`` on the ORM column)
    degrades to an empty string, never a raise; the cards line is unaffected."""
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
        user_prompt=None,
        status="prompt_ready",
        structured_prompt={"characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    assert ctx["user_prompt"] == ""
    # Cards line still intact — degradation didn't drop knowledge.
    assert [c["id"] for c in ctx["characters"]] == [character.id]


def test_writer_task_block_omits_bible_line_when_user_prompt_blank():
    """A whitespace-only (or empty) user_prompt renders no Bible line at all —
    the task block falls back to whatever structured_prompt fields exist."""
    context = {
        "user_prompt": "   \n  ",
        "structured_prompt": {"scene_setting": "推进"},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
    }
    llm = _CapturingStreamLLM()
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "本章节 Bible" not in llm.last_user
    assert "场景：推进" in llm.last_user


def test_writer_still_streams_without_user_prompt(db_session):
    """Writer must run end-to-end when user_prompt is missing (降级)."""
    book = Book(title="长夜")
    db_session.add(book)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=1,
        user_prompt=None,
        status="prompt_ready",
        structured_prompt={"characters_involved": []},
    )
    db_session.add(current)
    db_session.commit()

    ctx = build_writer_context(db_session, book, current)
    # v1.2.0 (HH) P7: WriterAgent.stream yields typed StreamChunk now.
    out = "".join(chunk.text for chunk in WriterAgent(MockLLMClient()).stream(ctx) if chunk.kind == "token")
    # MockLLMClient yields two prose fragments — proves the stream ran.
    assert out  # non-empty → did not raise / stall


# --------------------------------------------------------------------------
# Gate C — Writer persona + operational rules teach the Bible-authority rule
# --------------------------------------------------------------------------


def test_writer_persona_carries_boundary_segment():
    """The boundary must live in the DB-editable persona (not the rules)."""
    persona = DEFAULT_PERSONAS["writer"]
    assert "Bible" in persona
    assert "不越权推进 Bible 之外的剧情" in persona
    assert "连贯优先" in persona
    assert "水库" in persona  # 角色卡是水库不是清单
    # The deleted directive concept must not survive in the persona.
    assert "chapter_directive" not in persona


def test_writer_operational_rules_teach_bible_authority():
    """The Bible-authority rule + the exact required semantic sentence ride in
    the fixed operational rules, and the graceful-degrade instruction is
    present. The deleted directive/两条线 wording must be gone."""
    rules = WriterAgent.OPERATIONAL_RULES
    assert "本章节 Bible" in rules
    assert "情节的最高权威" in rules
    # P1 决议 #2 exact required semantic sentence.
    assert "请严格根据本章剧情来发挥并写作" in rules
    # Degrade instruction: behave when structured hints are absent.
    assert "结构要点为空时" in rules
    # Deleted concepts must not survive as dead text.
    assert "chapter_directive" not in rules
    assert "本章创作指令" not in rules
    assert "方向盘" not in rules


def test_writer_default_system_prompt_composes_persona_then_rules():
    """The composed default system prompt carries both the persona and the
    Bible-authority operational rule (regression surface for keyword tests)."""
    sp = WriterAgent.system_prompt
    assert sp.startswith(DEFAULT_PERSONAS["writer"])
    assert "本章节 Bible" in sp
    assert "只输出正文纯文本" in sp  # existing mechanics survive
    assert "chapter_directive" not in sp


# --------------------------------------------------------------------------
# Gate D — extractor append-only across chapters + §8.3 persona (untouched by
# P1 — never depended on chapter_directive)
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
