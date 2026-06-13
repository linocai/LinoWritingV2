from __future__ import annotations

# v1.0.0 EE Phase 2 (archive/v1.0.0_plan.md §7-Phase 2) gates:
#   1. persona runtime生效 — PATCHing a persona changes the Agent's runtime
#      ``system`` prompt (asserted against the captured LLM system, not the old
#      hardcoded literal).
#   2. directive 合规 — the Expander emits a 200-300 字 ``chapter_directive`` and
#      it does NOT leak character-card / author_notes content (P1 红线).
#   3. 优化师 context — ``build_expander_context`` injects the WHOLE outline
#      raw_text, carries NO per-chapter pre-sliced章纲 (P4 红线), and selects the
#      relevant-memory slice by ``characters_involved`` (not dump-all, P3).

import json
from typing import Any

from app.agents.prompt_expander import (
    CHAPTER_DIRECTIVE_MAX_CHARS,
    CHAPTER_DIRECTIVE_MIN_CHARS,
    PromptExpanderAgent,
)
from app.agents.writer import WriterAgent
from app.models.book import Book
from app.models.book_outline import BookOutline
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
        yield "一句正文。"


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


# --------------------------------------------------------------------------
# Gate 3 — 优化师 context (整份大纲 / 无预切章纲 / 相关记忆按 involved 选)
# --------------------------------------------------------------------------


def _seed_outline_world(db_session):
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
    outline_text = "这是一份约五千字的全书纯散文大纲，整份注入优化师。" * 30
    db_session.add(BookOutline(book_id=book.id, raw_text=outline_text))
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
    return book, c1, c2, current, outline_text


def test_expander_context_injects_whole_outline_verbatim(db_session):
    book, c1, c2, current, outline_text = _seed_outline_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    # ② whole outline, verbatim (not sliced / truncated).
    assert ctx["outline"] == outline_text


def test_expander_context_has_no_per_chapter_presliced_outline(db_session):
    """P4 红线: no pre-sliced per-chapter 章纲 anywhere in the context."""
    book, c1, c2, current, _ = _seed_outline_world(db_session)
    ctx = build_expander_context(db_session, book, current)
    # No banned slice keys leaked into the context dict.
    for banned in ("outline_slice", "chapter_outline", "arc_beats", "presliced_outline"):
        assert banned not in ctx
    # The current chapter's structured_prompt is not echoed back as a "slice".
    serialized = json.dumps(ctx, ensure_ascii=False, default=str)
    assert "outline_slice" not in serialized


def test_expander_context_relevant_memory_selected_by_characters_involved(db_session):
    """P3: the relevant-memory slice is the involved subset, not dump-all."""
    book, c1, c2, current, _ = _seed_outline_world(db_session)
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
    slice is empty, but the outline + all_characters pool are still present so
    the Expander can pick characters and infer focus_traits."""
    book = Book(title="新书")
    db_session.add(book)
    db_session.flush()
    char = Character(book_id=book.id, name="甲", role="主角", frozen_fields={}, live_fields={})
    db_session.add(char)
    db_session.add(BookOutline(book_id=book.id, raw_text="散文大纲。" * 50))
    chapter = Chapter(book_id=book.id, index=1, user_prompt="开篇", status="draft")
    db_session.add(chapter)
    db_session.commit()

    ctx = build_expander_context(db_session, book, chapter)
    assert ctx["involved_characters"] == []
    assert ctx["involved_timelines"] == {}
    assert ctx["outline"].startswith("散文大纲。")
    assert {c["id"] for c in ctx["all_characters"]} == {char.id}


def test_expander_context_outline_none_when_not_ingested(db_session):
    book = Book(title="无大纲")
    db_session.add(book)
    db_session.flush()
    chapter = Chapter(book_id=book.id, index=1, user_prompt="x", status="draft")
    db_session.add(chapter)
    db_session.commit()
    ctx = build_expander_context(db_session, book, chapter)
    assert ctx["outline"] is None
