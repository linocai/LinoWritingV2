from __future__ import annotations

# v1.0.0 EE Phase 2 (archive/v1.0.0_plan.md §7-Phase 2) gates, updated by
# v1.3.0 (II/JJ) P4/P8 去大纲化 (see PROJECT_PLAN §4.0 / §4 P4 / §4 P8) and by
# v1.4.0 (MM) P1 优化师降职 (see PROJECT_PLAN §4 P1):
#   1. persona runtime生效 — PATCHing a persona changes the Agent's runtime
#      ``system`` prompt (asserted against the captured LLM system, not the old
#      hardcoded literal).
#   2. continuity_alerts 合规 — the Expander emits ``continuity_alerts``
#      (list[str], a note FOR THE AUTHOR) and never invents plot to "fix" a
#      gap; the deleted ``chapter_directive`` slot (and its card-leak-guard
#      gate) is gone entirely — P1 决议 #1.
#   3. 优化师 context — ``build_expander_context`` carries NO ``outline`` key
#      (whole-book outline input deleted with the outline module), carries
#      ``recent_summaries`` (已完成章梗概, the new continuity-grounding input),
#      and selects the relevant-memory slice by ``characters_involved`` (not
#      dump-all, P3 — unchanged by the outline removal).

import json
from typing import Any

from app.agents.prompt_expander import PromptExpanderAgent
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
# Gate 2 — continuity_alerts 合规 (给作者的连续性提醒，绝不发明剧情去"修复")
#
# v1.4.0 (MM) P1 — 优化师降职: this gate used to cover the deleted
# ``chapter_directive`` slot (200-300 字 + card-leak guard). That whole
# steering-directive concept is gone — the author's own ``user_prompt`` is
# now the Writer's direct highest-authority input (see test_phase3). What
# remains of the Expander's "steering-adjacent" output is
# ``continuity_alerts`` — notes FOR THE AUTHOR, never read by the Writer.
# --------------------------------------------------------------------------


class _AlertingLLM(MockLLMClient):
    """Expander LLM that returns a full structured prompt + continuity alerts."""

    def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
        base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
        base["continuity_alerts"] = [
            "本章说林夕第一次见到黑刀，但第 2 章的梗概里两人已经交过手。",
            "world_setting 里雨城没有海，本章却写主角去了海边——与世界观冲突。",
        ]
        return base


def test_expander_emits_continuity_alerts_as_string_list():
    """The Expander's continuity/contradiction notes land in
    ``continuity_alerts`` — a plain list of one-sentence strings, distinct
    from every other structured field."""
    result = PromptExpanderAgent(_AlertingLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    alerts = result["continuity_alerts"]
    assert alerts == [
        "本章说林夕第一次见到黑刀，但第 2 章的梗概里两人已经交过手。",
        "world_setting 里雨城没有海，本章却写主角去了海边——与世界观冲突。",
    ]


def test_expander_continuity_alerts_defensively_drop_non_string_and_blank_items():
    """Same server-side defensive-list shape used elsewhere in this module
    (see ``PromptExpanderAgent.expand``'s ``chapter_style`` truncation) — a
    model that over-delivers junk into the list must not blow up the
    contract."""

    class _JunkAlertLLM(MockLLMClient):
        def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
            base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
            base["continuity_alerts"] = ["真实提醒。", "   ", 42, {"not": "a string"}, ""]
            return base

    result = PromptExpanderAgent(_JunkAlertLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    assert result["continuity_alerts"] == ["真实提醒。"]


def test_expander_continuity_alerts_empty_when_no_conflict():
    """No conflict found (the common case, and always true on chapter 1 with
    no prior memory) → an empty list, never a fabricated alert."""
    result = PromptExpanderAgent(MockLLMClient()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    assert result.get("continuity_alerts") == []


def test_expander_continuity_alerts_persist_through_the_expand_endpoint(client, auth_headers):
    """继续性提醒落库: the alerts round-trip through the DB via the real
    ``/expand`` endpoint (not just the in-process agent call) — proving
    they're actually persisted into ``chapter.structured_prompt``, not just
    an in-memory agent return value."""
    from app.llm.base import get_expander_llm_client
    from app.main import app

    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "长夜", "cover_color": "#111111"}
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角", "frozen_fields": {}, "live_fields": {}},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林夕在雨城调查一桩失踪案。"},
    ).json()

    app.dependency_overrides[get_expander_llm_client] = lambda: _AlertingLLM()
    try:
        resp = client.post(f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers)
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
    assert resp.status_code == 200, resp.text
    assert resp.json()["structured_prompt"]["continuity_alerts"] == [
        "本章说林夕第一次见到黑刀，但第 2 章的梗概里两人已经交过手。",
        "world_setting 里雨城没有海，本章却写主角去了海边——与世界观冲突。",
    ]

    # Re-fetch confirms the DB row itself carries it, not just the response.
    refetched = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert refetched["structured_prompt"]["continuity_alerts"] == [
        "本章说林夕第一次见到黑刀，但第 2 章的梗概里两人已经交过手。",
        "world_setting 里雨城没有海，本章却写主角去了海边——与世界观冲突。",
    ]


def test_expander_operational_rules_describe_continuity_alerts_as_author_facing():
    """P1 决议 #1: the rules must teach the model this is a note FOR THE
    AUTHOR (never a Writer input, never a "fix"), and the deleted
    ``chapter_directive``/200-300-字 concept must not survive as dead text."""
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "continuity_alerts" in rules
    assert "chapter_directive" not in rules
    # The boundary wording must survive a future "small tweak".
    assert "作者" in rules
    # v1.5.0 (NN) P1: the ``focus_traits`` responsibility (and its
    # ``author_notes``-as-trait-pool wording) is deleted entirely — no
    # replacement concept references author_notes in these rules any more.
    assert "focus_traits" not in rules


def test_expander_schema_advertises_continuity_alerts_and_no_directive():
    """The JSON schema must offer the ``continuity_alerts`` slot and no
    longer offer ``chapter_directive`` at all."""
    from app.agents.prompt_expander import _expander_json_schema

    schema = _expander_json_schema()
    alerts = schema["properties"]["continuity_alerts"]
    assert alerts["type"] == "array"
    assert alerts["items"] == {"type": "string"}
    assert "chapter_directive" not in schema["properties"]


def test_expander_schema_advertises_chapter_style_slot_and_no_focus_traits():
    """v1.5.0 (NN) P1: the schema must expose the new ``chapter_style`` slot
    (笼子②, 50-char cap mirrored here) and no longer offer the deleted
    ``focus_traits``/``extra_notes`` slots at all."""
    from app.agents.prompt_expander import _expander_json_schema

    schema = _expander_json_schema()
    style = schema["properties"]["chapter_style"]
    assert style["maxLength"] == 50
    assert "focus_traits" not in schema["properties"]
    assert "extra_notes" not in schema["properties"]


def test_expander_truncates_overlong_chapter_style_server_side():
    """笼子① — even if the LLM ignores the "≤50 字" instruction, ``expand()``
    truncates ``chapter_style`` server-side before validation (same defensive
    hand as the deleted focus_traits truncate used to be)."""

    class _OverlongStyleLLM(MockLLMClient):
        def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
            base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
            base["chapter_style"] = "字" * 80  # over the 50-char cap
            return base

    result = PromptExpanderAgent(_OverlongStyleLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    assert len(result["chapter_style"]) == 50


def test_expander_blank_chapter_style_normalizes_to_absent():
    """An all-whitespace chapter_style collapses to ``None`` (excluded from
    the persisted prompt by ``exclude_none``), never a dangling blank string."""

    class _BlankStyleLLM(MockLLMClient):
        def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
            base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
            base["chapter_style"] = "   "
            return base

    result = PromptExpanderAgent(_BlankStyleLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    assert "chapter_style" not in result


def test_expander_operational_rules_teach_chapter_style_cages():
    """The rules must teach the model both cages in prose: the ≤50 字 cap and
    the "只谈文字层面，禁情节/意象" boundary (schema alone is not enough — a
    model without structured-output support only ever sees the prose)."""
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "chapter_style" in rules
    assert "50 字" in rules
    assert "情节" in rules and "意象" in rules


def test_expander_operational_rules_frame_plot_anchors_as_guided_reading_not_checklist():
    """v1.5.0 (NN) P1 定案 #2: plot_anchors is framed as a 领读注解, not a
    验收清单 — the old must_happen concept and the deleted must_not_happen /
    focus_traits / chapter_goal / extra_notes fields must not survive as dead
    text in the rules."""
    rules = PromptExpanderAgent.OPERATIONAL_RULES
    assert "plot_anchors" in rules
    assert "领读注解" in rules
    assert "must_happen" not in rules
    assert "must_not_happen" not in rules
    assert "chapter_goal" not in rules
    assert "extra_notes" not in rules


def test_expander_pops_dead_chapter_directive_key_before_persisting(db_session):
    """审后修复 🔵 (archive/REVIEW_REPORT_v1.4.0.md): ``StructuredPrompt`` uses
    ``extra="allow"``, so a model that ignores OPERATIONAL_RULES could still
    smuggle a dead ``chapter_directive`` key back into a NEW chapter's
    structured_prompt. ``expand()`` must defensively pop it before returning
    (i.e. before the router persists the result) — the dead key must never be
    able to resurrect itself in freshly-written data, even though old rows
    that already have it are left alone (extra="allow" tolerates those)."""

    class _ResurrectsDirectiveLLM(MockLLMClient):
        def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
            base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
            base["chapter_directive"] = "模型自己编的方向盘，不该活下来。"
            return base

    result = PromptExpanderAgent(_ResurrectsDirectiveLLM()).expand(
        {"all_characters": [{"id": "c1", "name": "林夕", "role": "主角"}]}
    )
    assert "chapter_directive" not in result


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
    instead describe the TWO background-memory sections it DOES get
    (「前情大事记」/「上一章梗概」— v1.5.1 快修 retired the 200-字 summary
    middle tier) and warn against treating them as writing material to
    expand/restate."""
    rules = WriterAgent.OPERATIONAL_RULES
    assert "recent_fulltext" not in rules
    assert "前情大事记" in rules
    assert "上一章梗概" in rules
    assert "前情梗概" not in rules
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
    book = Book(title="长夜", world_setting="雨城")
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
        structured_prompt={"characters_involved": [c1.id]},
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
    characters (选角) and generate plot_anchors/chapter_style (领读)."""
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
