from __future__ import annotations

# v1.0.0 EE Phase 2 (archive/v1.0.0_plan.md §7-Phase 2) gates, updated by
# v1.3.0 (II/JJ) P4/P8 去大纲化 (see PROJECT_PLAN §4.0 / §4 P4 / §4 P8):
#   1. persona runtime生效 — PATCHing a persona changes the Agent's runtime
#      ``system`` prompt (asserted against the captured LLM system, not the old
#      hardcoded literal).
#   2. directive 合规 — the Expander emits a 200-300 字 ``chapter_directive`` and
#      it does NOT leak character-card / author_notes content (P1 红线).
#   3. 优化师 context — ``build_expander_context`` carries NO ``outline`` key
#      (whole-book outline input deleted with the outline module), carries
#      ``recent_summaries`` (已完成章梗概, the new continuity-grounding input),
#      and selects the relevant-memory slice by ``characters_involved`` (not
#      dump-all, P3 — unchanged by the outline removal).

import json
from typing import Any

from app.agents.prompt_expander import (
    CHAPTER_DIRECTIVE_MAX_CHARS,
    CHAPTER_DIRECTIVE_MIN_CHARS,
    PromptExpanderAgent,
)
from app.agents.writer import WriterAgent
from app.llm.base import StreamChunk
from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent
from app.services.context_pack import build_expander_context
from app.services.personas import DEFAULT_PERSONAS
from tests.conftest import MockLLMClient


# --------------------------------------------------------------------------
# Gate 1 — persona runtime生效 (via the /write router + get_persona DB read)
# --------------------------------------------------------------------------


class _SystemCapturingStreamLLM(MockLLMClient):
    """Captures the ``system`` the Writer hands to the LLM, then streams once."""

    last_system: str | None = None

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):
        type(self).last_system = system
        yield StreamChunk(kind="token", text="一句正文。")


def _seed_book_character(client, auth_headers):
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


def test_writer_persona_patch_changes_runtime_system_prompt(client, auth_headers):
    """PATCH the Writer persona, then run /write and assert the captured
    runtime ``system`` carries the *new* DB persona — not the seed default."""
    from app.main import app
    from app.llm.base import get_writer_llm_client

    book, character = _seed_book_character(client, auth_headers)
    created = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "雨夜", "user_prompt": "林夕找线索。"},
    ).json()
    client.post(f"/api/v1/chapters/{created['id']}/expand", headers=auth_headers)

    sentinel = "我是被作者改过的 Writer 人格 SENTINEL_2026。"
    patched = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"system_prompt": sentinel},
    )
    assert patched.status_code == 200

    # Swap in the system-capturing LLM only for the Writer dependency.
    _SystemCapturingStreamLLM.last_system = None
    app.dependency_overrides[get_writer_llm_client] = lambda: _SystemCapturingStreamLLM()
    try:
        with client.stream(
            "POST", f"/api/v1/chapters/{created['id']}/write", headers=auth_headers
        ) as response:
            "".join(response.iter_text())
            assert response.status_code == 200
    finally:
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()

    captured = _SystemCapturingStreamLLM.last_system
    assert captured is not None
    # The new DB persona text is present...
    assert sentinel in captured
    # ...and the seeded default persona's distinctive line is gone (the persona
    # layer was actually replaced, not appended-to).
    assert "你是有稳定文风的中文小说家" not in captured
    # The fixed operational rules still ride along (not part of the persona).
    assert "只输出正文纯文本" in captured


def test_writer_agent_composes_persona_in_front_of_operational_rules():
    """Unit-level: the constructor persona lands ahead of the fixed rules."""
    agent = WriterAgent(MockLLMClient(), persona="人格甲乙丙。")
    assert agent.system_prompt.startswith("人格甲乙丙。")
    assert "只输出正文纯文本" in agent.system_prompt
    # Bare constructor falls back to the code-level default persona.
    default_agent = WriterAgent(MockLLMClient())
    assert default_agent.system_prompt.startswith(DEFAULT_PERSONAS["writer"])


# --------------------------------------------------------------------------
# Gate 2 — directive 合规 (200-300 字 + 不泄漏人物卡)
# --------------------------------------------------------------------------

# A leak-bait directive: realistic 本章创作指令 prose that stays STEERING —
# direction / tension / open伏笔 — and deliberately avoids any card field name
# or author_notes fragment. ~250 chars (between MIN and MAX).
_CLEAN_DIRECTIVE = (
    "本章要把林夕推到第一个真正的抉择口。开篇延续上一章山洞的余震，让他在"
    "返程途中意识到自己掌握的线索并不完整，必须决定是独自追下去还是回城求援。"
    "全章的张力压在「信任」二字上：他既想保护身边的人，又无法判断谁值得托付。"
    "请把这种犹疑写进他的每一个停顿与回头，而不是直接说明。中段安排一次看似偶然的"
    "相遇，把上一卷埋下的那枚铜钱伏笔轻轻拨动一下，但不要揭晓它的来历，留到后续。"
    "落点收在他做出选择的瞬间，让读者明白代价已经种下，却还看不清全貌。整体节奏"
    "前缓后紧，结尾留一个向下一章敞开的钩子。"
)

# Field names / author_notes fragments that MUST NOT appear in the directive.
_CARD_LEAK_MARKERS = (
    "frozen_fields",
    "live_fields",
    "author_notes",
    "core_traits",
    "current_status",
    "为妹妹复仇",  # author_notes.motivation fragment
    "童年纵火",  # author_notes.secret fragment
)


class _DirectiveLLM(MockLLMClient):
    """Expander LLM that returns a full structured prompt + clean directive."""

    def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
        base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
        base["chapter_directive"] = _CLEAN_DIRECTIVE
        return base


def test_expander_emits_chapter_directive_within_length_band():
    result = PromptExpanderAgent(_DirectiveLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    directive = result["chapter_directive"]
    assert directive is not None
    assert CHAPTER_DIRECTIVE_MIN_CHARS <= len(directive) <= CHAPTER_DIRECTIVE_MAX_CHARS


def test_expander_directive_does_not_leak_character_card_content():
    """P1 红线: chapter_directive is steering, never copied card / author_notes."""
    result = PromptExpanderAgent(_DirectiveLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    directive = result["chapter_directive"]
    for marker in _CARD_LEAK_MARKERS:
        assert marker not in directive, f"directive leaked card marker: {marker!r}"


def test_expander_schema_advertises_chapter_directive_with_no_leak_guard():
    """The JSON schema must offer the slot AND tell the model not to copy card
    content into it (double guard alongside the persona [边界] 段)."""
    from app.agents.prompt_expander import _expander_json_schema

    schema = _expander_json_schema()
    directive = schema["properties"]["chapter_directive"]
    assert "string" in directive["type"]
    desc = directive["description"].lower()
    assert "steering" in desc
    assert "never copy" in desc


def test_expander_operational_rules_forbid_copying_cards_into_directive():
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "chapter_directive" in rules
    assert "200" in rules and "300" in rules
    # The boundary wording must survive a future "small tweak".
    assert "绝不" in rules
    assert "author_notes" in rules


def test_expander_operational_rules_describe_three_tier_memory_input():
    """v1.3.2 (LL) P3: the OPERATIONAL_RULES input description must mention
    all three memory tiers — recent_fulltext (最近 3 章原文), recent_summaries
    (再往前章梗概), and recent_headlines (更早一句话大事记) — so a future edit
    can't silently regress the description back to the old
    two-tier/summaries-only wording."""
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "recent_fulltext" in rules
    assert "recent_summaries" in rules
    assert "recent_headlines" in rules


def test_writer_operational_rules_describe_background_memory_sections():
    """v1.3.4 快修 (作者实测报障): the Writer no longer receives ANY raw
    prior-chapter prose (``recent_fulltext`` deleted from its context/rules
    entirely — see context_pack.py/writer.py). Its OPERATIONAL_RULES must
    instead describe the three background-memory sections it DOES get
    (「前情梗概」/「上一章梗概」/「更早章节大事记」) and warn against
    treating them as writing material to expand/restate."""
    rules = WriterAgent.OPERATIONAL_RULES
    assert "recent_fulltext" not in rules
    assert "前情梗概" in rules
    assert "上一章梗概" in rules
    assert "大事记" in rules
    assert "不要展开" in rules


def test_expander_operational_rules_reference_world_setting():
    """v1.3.3 快修 (作者实测报障): the Expander context has carried
    ``world_setting`` since v1.0.0 but the rules never named it — the
    continuity check silently excluded the author's worldview. Locks the
    input-list mention and the setting-conflict check."""
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "world_setting" in rules
    assert "世界观" in rules


def test_extractor_operational_rules_pin_summary_first_sentence_headline():
    """v1.3.3 快修: recent_headlines (v1.3.2 LL P3) is mechanically the FIRST
    SENTENCE of the extractor's summary — so the extractor must be told to
    lead with the chapter's most important event, or the whole headline tier
    inherits whatever filler sentence happens to come first."""
    from app.agents.extractor import ExtractorAgent

    rules = ExtractorAgent.OPERATIONAL_RULES
    assert "第一句" in rules
    assert "大事记" in rules


# --------------------------------------------------------------------------
# Gate 3 — 优化师 context (无 outline 键 / recent_summaries 在 / 相关记忆按
# involved 选) — rewritten for v1.3.0 (II/JJ) P4 去大纲化 (P8, see
# PROJECT_PLAN §4 P4 / P8: the Expander no longer reads a whole-book outline;
# continuity is grounded in ``recent_summaries`` instead).
# --------------------------------------------------------------------------


def _seed_memory_world(db_session):
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()
    c1 = Character(
        book_id=book.id,
        name="林夕",
        role="主角",
        frozen_fields={"core_traits": "谨慎"},
        live_fields={"current_status": "调查"},
        author_notes={"motivation": "为妹妹复仇"},
    )
    c2 = Character(
        book_id=book.id,
        name="黑刀",
        role="反派",
        frozen_fields={"core_traits": "沉默"},
        live_fields={},
    )
    db_session.add_all([c1, c2])
    db_session.flush()
    # A finalized prior chapter with a summary — the new continuity-grounding
    # input (``recent_summaries``), replacing the old whole-book outline.
    prior = Chapter(
        book_id=book.id,
        index=1,
        user_prompt="第一章的本章剧情叙述。",
        status="finalized",
        summary="林夕在山洞发现一枚旧信。",
    )
    db_session.add(prior)
    db_session.flush()
    current = Chapter(
        book_id=book.id,
        index=2,
        user_prompt="本章意图",
        status="prompt_ready",
        # Only c1 is involved → relevant-memory slice must contain c1, not c2.
        structured_prompt={"chapter_goal": "推进", "characters_involved": [c1.id]},
    )
    db_session.add(current)
    db_session.flush()
    db_session.add(
        TimelineEvent(
            book_id=book.id,
            character_id=c1.id,
            chapter_id=current.id,
            event_type="action",
            event_text="发现旧信。",
        )
    )
    db_session.commit()
    return book, c1, c2, current, prior


def test_expander_context_has_no_outline_key(db_session):
    """P4 红线: the whole-book outline input is gone — ``build_expander_context``
    must not carry an ``outline`` key at all (not even ``None``)."""
    book, c1, c2, current, _ = _seed_memory_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    assert "outline" not in ctx


def test_expander_context_carries_recent_summaries(db_session):
    """The new continuity-grounding input: already-finalized chapter summaries,
    replacing the old whole-book outline read.

    v1.3.1 (KK) P7: ``prior`` here has no ``draft_text`` (only a ``summary``),
    so it correctly falls to ``recent_summaries`` rather than the fulltext
    window (``recent_fulltext`` requires non-empty draft_text) — locks that
    a summary-only finalized chapter still surfaces via recent_summaries."""
    book, c1, c2, current, prior = _seed_memory_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    assert ctx["recent_summaries"] == [{"index": prior.index, "summary": prior.summary}]
    assert ctx["recent_fulltext"] == []
    # v1.3.2 (LL) P3: 1 chapter is well under RECENT_SUMMARY_COUNT=30, so
    # nothing spills into the third (headline) tier yet.
    assert ctx["recent_headlines"] == []


def test_expander_context_has_no_per_chapter_presliced_outline(db_session):
    """P4 红线: no pre-sliced per-chapter 章纲 anywhere in the context."""
    book, c1, c2, current, _ = _seed_memory_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    # No banned slice keys leaked into the context dict.
    for banned in ("outline_slice", "chapter_outline", "arc_beats", "presliced_outline"):
        assert banned not in ctx
    # The current chapter's structured_prompt is not echoed back as a "slice".
    serialized = json.dumps(ctx, ensure_ascii=False, default=str)
    assert "outline_slice" not in serialized


def test_expander_context_relevant_memory_selected_by_characters_involved(db_session):
    """P3: the relevant-memory slice is the involved subset, not dump-all."""
    book, c1, c2, current, _ = _seed_memory_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    involved_ids = [c["id"] for c in ctx["involved_characters"]]
    assert involved_ids == [c1.id]  # c2 (not involved) excluded from the slice.
    assert c2.id not in involved_ids
    # The involved slice carries that character's recent timeline.
    assert list(ctx["involved_timelines"].keys()) == [c1.id]
    assert ctx["involved_timelines"][c1.id][0]["event_text"] == "发现旧信。"
    # all_characters (the selection pool for characters_involved) still has both.
    assert {c["id"] for c in ctx["all_characters"]} == {c1.id, c2.id}


def test_expander_context_first_pass_empty_involved_slice(db_session):
    """Before the first expand, characters_involved is empty → the relevant
    slice is empty, but ``recent_summaries``/``recent_fulltext``/
    ``recent_headlines`` (all empty, no prior chapters here — v1.3.2 LL P3
    three-tier memory, no regression on the first chapter's empty window)
    and the all_characters pool are still present so the Expander can pick
    characters and infer focus_traits."""
    book = Book(title="新书")
    db_session.add(book)
    db_session.flush()
    char = Character(book_id=book.id, name="甲", role="主角", frozen_fields={}, live_fields={})
    db_session.add(char)
    chapter = Chapter(book_id=book.id, index=1, user_prompt="开篇", status="draft")
    db_session.add(chapter)
    db_session.commit()

    ctx = build_expander_context(db_session, book, chapter)
    assert ctx["involved_characters"] == []
    assert ctx["involved_timelines"] == {}
    assert ctx["recent_summaries"] == []
    assert ctx["recent_fulltext"] == []
    assert ctx["recent_headlines"] == []
    assert "outline" not in ctx
    assert {c["id"] for c in ctx["all_characters"]} == {char.id}
