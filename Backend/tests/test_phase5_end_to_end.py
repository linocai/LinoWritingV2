from __future__ import annotations

# v1.0.0 EE Phase 5 (archive/v1.0.0_plan.md §7-Phase 5) — link-up 联调 +
# architecture-invariant verification. Updated by v1.3.0 (II/JJ) P4/P8 去大纲化
# (see PROJECT_PLAN §4.0 / §4 P4 / §4 P8): the whole-book outline input is gone;
# the Expander now locates "where the story is" purely via ``recent_summaries``
# (已完成章梗概) — the invariants below are rewritten accordingly.
#
# v1.3.1 (KK) P7 — 记忆分层两层: INV-1/INV-1b were rewritten to lock a two-tier
# memory contract (bounded fulltext + unbounded summary) instead of the old
# "zero prior prose, ever" rule.
#
# v1.3.2 (LL) P3 — 记忆第三层「一句话大事记」: INV-1'/INV-1b' are further
# rewritten (not deleted) into INV-1'' to lock the new THREE-tier contract.
# The nearest RECENT_FULLTEXT_COUNT (3) finalized chapters carry FULL
# draft_text (``recent_fulltext``); the next ``RECENT_SUMMARY_COUNT`` older
# chapters carry FULL summary (``recent_summaries``, now also bounded —
# monkeypatched small in this test so the run doesn't need 30+ chapters to
# reach the third tier); anything older still is a mechanically-distilled
# one-line ``headline`` (``recent_headlines``). See INV-1'' below.
#
# This is NOT the real 100-chapter LLM long run (that is a user-side, real-key,
# real-device task per §D7). Here we drive the FULL HTTP chain end-to-end with
# *mock* LLMs that RECORD the context each agent receives, then assert — over a
# rolling, multi-chapter run — that the architecture red lines hold:
#
#   闭环 (closed loop):
#     author imports initial cards → create chapter → expand (优化师
#     just-in-time reads 已完成章梗概 recent_summaries + relevant memory, emits
#     chapter_directive) → write (Writer uses directive + cards/timelines) →
#     finalize (档案员 writes back structured memory) → next chapter, whose
#     expander/writer context can read the PREVIOUS chapter's written-back
#     memory (proves memory rolls + the story advances without a position
#     pointer).
#
#   不变量 (invariants), asserted across ≥5 chapters (the closed loop below
#   runs 5; INV-4's decoy-character check extends it to a 6th):
#     INV-1'' (P3, was INV-1'/INV-1b' at P7) THREE-tier memory, each tier
#            exclusive and bounded except the last:
#            · the FULLTEXT channel (``recent_fulltext``) is bounded at
#              exactly RECENT_FULLTEXT_COUNT (3) chapters and does NOT grow
#              with total chapter count;
#            · the FULL-SUMMARY channel (``recent_summaries``) is bounded at
#              exactly the (monkeypatched-small, for this test) summary limit
#              — also does NOT grow past that bound (was unbounded pre-P3);
#            · any chapter older than BOTH windows reaches Expander/Writer
#              ONLY as a one-line ``headline`` (``recent_headlines``), never
#              as full prose or full summary — and every chapter strictly
#              older than the current one falls into EXACTLY ONE of the three
#              tiers (no gaps, no double-counting).
#            Also (was INV-1b'): when the fulltext window is hit (at least
#            one chapter lands in ``recent_fulltext``), the Writer's OTHER
#            prior-prose channel — ``style_samples`` — is empty (``[]``), so
#            the same chapters are never double-fed as both recent_fulltext
#            and style_samples.
#     INV-2  (P4) the Expander context carries NO ``outline`` key and NO
#            pre-sliced per-chapter 章纲 key — it locates itself purely by
#            memory (recent_summaries, no position pointer).
#     INV-3  (P1) the directive leaks no card content; the Writer reads 方向
#            (directive) and 知识 (cards/timeline) on two distinct lines.
#     INV-4  (P3) under multiple chapters the Context Pack selects only the
#            relevant (involved) cards, never dump-all.
#     INV-5  (P2) the 档案员 write-back is append-only — chapter N's extraction
#            never wipes chapter N-1's timeline; memory accumulates.
#     INV-6  one closed loop writes agent_logs for all three agents
#            (expander / writer / extractor).

import json
from typing import Any

from app.llm.base import (
    StreamChunk,
    get_expander_llm_client,
    get_extractor_llm_client,
    get_writer_llm_client,
)
from app.main import app
from tests.conftest import MockLLMClient

# Directive prose (STEERING) — carries no card field name / author_notes.
_DIRECTIVE = (
    "本章把林夕推到一个抉择口：独自追下去还是回城求援。张力压在「信任」上，"
    "请把犹疑写进停顿与回头，落点收在他做出选择的瞬间，结尾留一个向下一章敞开的钩子。"
)

# Markers that would betray a card-content leak into the directive (P1).
_CARD_LEAK_MARKERS = (
    "frozen_fields",
    "live_fields",
    "author_notes",
    "core_traits",
    "current_status",
    "为妹妹复仇",  # author_notes.motivation fragment we seed below
)


# --------------------------------------------------------------------------
# Recording mock LLMs — produce valid output AND capture the context each agent
# saw, keyed by the chapter index, so we can assert invariants per chapter.
# --------------------------------------------------------------------------


class _RecordingExpanderLLM(MockLLMClient):
    def __init__(self) -> None:
        self.contexts: list[dict[str, Any]] = []

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        context = json.loads(user)
        self.contexts.append(context)
        # Pick involved characters from the all_characters pool (MockLLMClient
        # default selects the first), then bolt on a clean directive.
        base = super().complete_json(system=system, user=user, schema=schema, **kwargs)
        base["chapter_directive"] = _DIRECTIVE
        return base


# Bounded style-reference window (the v0.6 §5.A "学习前文文风" channel). The
# Writer is fed head + tail snippets of at most this many recent finalized
# chapters — NOT the full bodies, and NOT growing with chapter count. This is
# why P2 holds at chapter 100. We mirror the constants here to assert the bound.
#
# v1.3.2 (LL) P3: RECENT_FULLTEXT_COUNT mirrors the three-tier memory window —
# INV-1'' below asserts it (and the summary tier) stay bounded regardless of
# total chapter count (replacing the v1.3.1 KK P7 two-tier INV-1'/INV-1b').
from app.services.context_pack import (  # noqa: E402
    HEADLINE_MAX_CHARS,
    RECENT_FULLTEXT_COUNT,
    STYLE_SAMPLES_CHAPTER_COUNT,
    STYLE_SAMPLES_CHARS_PER_SIDE,
    _distill_headline,
)

# A unique marker per chapter, buried in the MIDDLE of a long body so it falls
# OUTSIDE the bounded head/tail style-sample window — that lets us assert "the
# full prior body is never fed back" cleanly, distinct from the (bounded,
# legitimate) head/tail style-reference snippets.
_BODY_FILLER = "雨声压低了山洞里的呼吸，林夕在石缝中摸到一枚带血的铜钱。" * 30


def _chapter_body(idx: int) -> str:
    # marker sits in the middle, well past the first/last 400 chars.
    return f"{_BODY_FILLER}【正文核心_{idx}_MIDMARKER】{_BODY_FILLER}"


class _RecordingWriterLLM(MockLLMClient):
    def __init__(self) -> None:
        self.systems: list[str] = []
        self.users: list[str] = []

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):
        self.systems.append(system)
        self.users.append(user)
        context = json.loads(user.split("\n\n")[0])
        idx = context.get("structured_prompt", {}).get("_chapter_index", "?")
        # Stream a long body with a unique mid-body marker (see _chapter_body).
        yield StreamChunk(kind="token", text=_chapter_body(idx))


class _RecordingExtractorLLM(MockLLMClient):
    """Stamps each chapter's timeline event + live_fields with the chapter's own
    draft_text so events from different chapters are distinguishable, and the
    rolled-forward live_fields reflects the latest chapter."""

    def __init__(self) -> None:
        self.contexts: list[dict[str, Any]] = []

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        context = json.loads(user)
        self.contexts.append(context)
        character = context["characters"][0]
        draft = context["chapter"]["draft_text"]
        idx = context["chapter"]["index"]
        return {
            "summary": f"第{idx}章摘要：{draft[:18]}",
            "timeline_events": [
                {
                    "character_id": character["id"],
                    "event_type": "action",
                    "event_text": f"事件@第{idx}章",
                }
            ],
            "character_updates": [
                {
                    "character_id": character["id"],
                    "live_fields_patch": {"current_status": f"走到第{idx}章末"},
                }
            ],
        }


# --------------------------------------------------------------------------
# Driving helpers — one chapter through the FULL HTTP chain.
# --------------------------------------------------------------------------


def _seed_book_with_card(client, auth_headers) -> tuple[dict, dict]:
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "雨城三部曲", "cover_color": "#111111", "style_directive": "克制"},
    ).json()
    # Author imports the initial character card (no outline module anymore —
    # v1.3.0 JJ P4/P5 deleted it; the Expander now locates itself via
    # recent_summaries instead of a whole-book outline).
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎", "background": "退役追踪员"},
            "live_fields": {"current_status": "调查失踪案"},
            "author_notes": {"motivation": "为妹妹复仇"},
        },
    ).json()
    return book, character


def _run_chapter(client, auth_headers, book_id: str, index_hint: int) -> dict:
    """Create → expand → write → finalize one chapter. Returns the finalized
    chapter dict."""
    created = client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"title": f"第{index_hint}章", "user_prompt": f"第{index_hint}章意图"},
    ).json()
    chapter_id = created["id"]

    # expand — 优化师 just-in-time
    r = client.post(f"/api/v1/chapters/{chapter_id}/expand", headers=auth_headers)
    assert r.status_code == 200, r.text
    sp = r.json()["structured_prompt"]
    assert sp.get("chapter_directive") == _DIRECTIVE
    # Stamp the chapter index into structured_prompt so the writer mock can label
    # its prose uniquely. Goes through the PATCH allowlist (structured_prompt).
    sp["_chapter_index"] = index_hint
    rp = client.patch(
        f"/api/v1/chapters/{chapter_id}",
        headers=auth_headers,
        json={"structured_prompt": sp},
    )
    assert rp.status_code == 200, rp.text

    # write — Writer (SSE)
    with client.stream(
        "POST", f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers
    ) as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())
    assert "done" in body

    # finalize — 档案员 write-back
    r = client.post(f"/api/v1/chapters/{chapter_id}/finalize", headers=auth_headers)
    assert r.status_code == 200, r.text
    assert r.json()["chapter"]["status"] == "finalized"
    return r.json()["chapter"]


# --------------------------------------------------------------------------
# The end-to-end closed-loop test — 5 chapters, all invariants.
#
# v1.3.1 (KK) P7 审后修复 🟡4 (reviewer 抓出): the loop used to run only 3
# chapters (== RECENT_FULLTEXT_COUNT), so the "chapter older than the window
# reaches the agents ONLY as summary" branch of INV-1' was structurally
# unreachable — every `earlier` index was always inside the fulltext window,
# so the marker-leak assertion's `continue` fired every time and the check
# never actually ran. A 4-chapter loop is STILL not enough: when chapter 4
# runs, only chapters 1-3 are finalized yet, and all 3 fit inside the
# RECENT_FULLTEXT_COUNT=3 window — so chapter 1 is still "inside the window"
# from chapter 4's point of view. The window only genuinely excludes a
# chapter once 4 PRIOR chapters exist, i.e. when processing chapter 5 (prior
# finalized = {1,2,3,4}, fulltext = nearest 3 = {2,3,4}, chapter 1 is finally
# outside). Bumped the loop to 5 chapters so the "windowed-out chapters are
# summary-only" claim is genuinely exercised, not just a `continue` no-op.
# --------------------------------------------------------------------------


def test_end_to_end_three_chapter_closed_loop_holds_all_invariants(client, auth_headers, monkeypatch):
    # v1.3.2 (LL) P3 审后教训 (KK 🟡4 复现风险): monkeypatch the full-summary
    # tier down to a tiny limit so this run's chapter count (5 + the INV-4
    # decoy chapter = 6) is enough to genuinely PENETRATE all three memory
    # tiers — fulltext (3) + full-summary (this patched value) + headline
    # (everything older still) — instead of relying on a `continue` no-op
    # that never actually reaches the headline branch. Production default
    # (RECENT_SUMMARY_COUNT=30, author-locked, PROJECT_PLAN §4 已决议 #3) is
    # untouched; only this test's constant is shrunk.
    _TEST_SUMMARY_LIMIT = 1
    monkeypatch.setattr("app.services.context_pack.RECENT_SUMMARY_COUNT", _TEST_SUMMARY_LIMIT)

    expander_llm = _RecordingExpanderLLM()
    writer_llm = _RecordingWriterLLM()
    extractor_llm = _RecordingExtractorLLM()

    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        book, character = _seed_book_with_card(client, auth_headers)

        chapters = [_run_chapter(client, auth_headers, book["id"], i) for i in (1, 2, 3, 4, 5)]
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()

    # The loop actually ran 5 chapters to finalized.
    assert [c["status"] for c in chapters] == ["finalized"] * 5
    assert len(expander_llm.contexts) == 5
    assert len(writer_llm.users) == 5
    assert len(extractor_llm.contexts) == 5

    char_id = character["id"]

    # ----- INV-2 (P4): every Expander context has NO ``outline`` key (whole-book
    #       outline input deleted) and NO pre-sliced per-chapter 章纲 key. --------
    for ctx in expander_llm.contexts:
        assert "outline" not in ctx
        for banned in ("outline_slice", "chapter_outline", "arc_beats", "presliced_outline"):
            assert banned not in ctx
        # No position pointer key smuggled in.
        serialized = json.dumps(ctx, ensure_ascii=False, default=str)
        assert "outline_slice" not in serialized

    # ----- INV-1'' (P3, was INV-1'/INV-1b' at P7): chapter N (N≥2)
    #       Expander/Writer context's three memory tiers are each bounded
    #       (except the last) and mutually exclusive — every chapter strictly
    #       older than N falls into EXACTLY ONE of fulltext / full-summary /
    #       headline, never zero, never more than one, and never re-fed as
    #       full body/summary outside its own tier.
    def _assert_three_tier_invariants(n: int) -> None:
        exp_ctx = expander_llm.contexts[n - 1]
        wri_payload = json.loads(writer_llm.users[n - 1].split("\n\n")[0])

        exp_fulltext = exp_ctx.get("recent_fulltext", [])
        wri_fulltext = wri_payload.get("recent_fulltext", [])
        exp_summaries = exp_ctx.get("recent_summaries", [])
        wri_summaries = wri_payload.get("recent_summaries", [])
        exp_headlines = exp_ctx.get("recent_headlines", [])
        wri_headlines = wri_payload.get("recent_headlines", [])

        # Fulltext bounded at RECENT_FULLTEXT_COUNT; full-summary bounded at
        # the (test-patched) summary limit — neither grows past its bound.
        assert len(exp_fulltext) <= RECENT_FULLTEXT_COUNT, f"ch{n} expander fulltext window exceeded bound"
        assert len(wri_fulltext) <= RECENT_FULLTEXT_COUNT, f"ch{n} writer fulltext window exceeded bound"
        assert len(exp_summaries) <= _TEST_SUMMARY_LIMIT, f"ch{n} expander summary window exceeded bound"
        assert len(wri_summaries) <= _TEST_SUMMARY_LIMIT, f"ch{n} writer summary window exceeded bound"

        fulltext_indices = {c["index"] for c in exp_fulltext}
        summary_indices = {s["index"] for s in exp_summaries}
        headline_indices = {h["index"] for h in exp_headlines}
        assert fulltext_indices == {c["index"] for c in wri_fulltext}, f"ch{n} expander/writer fulltext disagree"
        assert summary_indices == {s["index"] for s in wri_summaries}, f"ch{n} expander/writer summary disagree"
        assert headline_indices == {h["index"] for h in wri_headlines}, f"ch{n} expander/writer headline disagree"

        serialized_exp = json.dumps(exp_ctx, ensure_ascii=False, default=str)
        wri_user = writer_llm.users[n - 1]
        for earlier in range(1, n):
            in_fulltext = earlier in fulltext_indices
            in_summary = earlier in summary_indices
            in_headline = earlier in headline_indices
            assert in_fulltext or in_summary or in_headline, (
                f"ch{n}: ch{earlier} missing from all three memory tiers"
            )
            assert sum([in_fulltext, in_summary, in_headline]) == 1, (
                f"ch{n}: ch{earlier} double-counted across memory tiers"
            )
            if in_fulltext:
                continue  # inside the legitimate bounded full-prose window — expected.
            # summary or headline tier — the mid-body marker (sits outside the
            # bounded head/tail style window too) must never leak, proving no
            # full-body re-feed for chapters outside the fulltext window.
            marker = f"【正文核心_{earlier}_MIDMARKER】"
            assert marker not in serialized_exp, f"ch{n} expander ctx leaked ch{earlier} full body outside window"
            assert marker not in wri_user, f"ch{n} writer ctx leaked ch{earlier} full body outside window"

    for n in (2, 3, 4, 5):
        _assert_three_tier_invariants(n)

    # Positive (memory rolls — the optimizer locates itself via memory, P4):
    # chapter 2/3/4/5's Expander sees the PRIOR chapter's write-back via
    # recent_summaries (a finalized chapter's summary) OR recent_fulltext (if
    # still inside the bounded window) — not via some other re-fed channel.
    for n in (2, 3, 4, 5):
        exp_ctx = expander_llm.contexts[n - 1]
        summaries = exp_ctx.get("recent_summaries", [])
        fulltext = exp_ctx.get("recent_fulltext", [])
        seen_in_summaries = any(f"第{n - 1}章摘要" in (s.get("summary") or "") for s in summaries)
        seen_in_fulltext = any(c.get("index") == n - 1 for c in fulltext)
        assert seen_in_summaries or seen_in_fulltext, (
            f"ch{n} expander did not see ch{n - 1}'s written-back memory in "
            f"either recent_summaries or recent_fulltext"
        )

    # Positive (memory rolls — Writer side): chapter 2/3/4/5's Writer sees the
    # rolled-forward memory on the 知识 line — the involved card's updated
    # live_fields + the prior chapter's timeline event — never the prior body.
    for n in (2, 3, 4, 5):
        payload = json.loads(writer_llm.users[n - 1].split("\n\n")[0])
        timelines = payload.get("timelines", {})
        events = timelines.get(char_id, [])
        event_texts = {e["event_text"] for e in events}
        assert f"事件@第{n - 1}章" in event_texts, f"ch{n} writer missing ch{n - 1}'s timeline"
        card_status = payload["characters"][0]["live_fields"]["current_status"]
        assert card_status == f"走到第{n - 1}章末", f"ch{n} writer card not rolled forward"

    # INV-1'' anti-duplication half (was INV-1b' at P7): when the fulltext
    # window is hit (at least one chapter lands in recent_fulltext), the
    # Writer's OTHER prior-prose channel — style_samples — must be EMPTY, so
    # the same chapters are never double-fed as both recent_fulltext and
    # style_samples (anti-duplication rule). By chapter 5, the fulltext
    # window (size 3) covers only the 3 most recent finalized chapters
    # (2,3,4) and chapter 1 has rolled OUT into summary-only — the window is
    # genuinely bounded, not just "big enough to swallow everything so far"
    # as it was at n=2..4.
    last_writer_payload = json.loads(writer_llm.users[-1].split("\n\n")[0])
    last_fulltext = last_writer_payload.get("recent_fulltext", [])
    style_samples = last_writer_payload.get("style_samples", [])
    assert len(last_fulltext) > 0, "expected the fulltext window to have hit by chapter 5"
    assert len(last_fulltext) <= RECENT_FULLTEXT_COUNT, "fulltext window must stay bounded even past chapter 5"
    assert [c["index"] for c in last_fulltext] == [2, 3, 4], "fulltext window must be exactly the nearest 3 chapters"
    assert style_samples == [], "style_samples must be empty when the fulltext window hit (no duplicate feed)"

    # ----- INV-3 (P1): directive leaks no card content; Writer reads two lines. --
    for wri_user in writer_llm.users:
        payload = json.loads(wri_user.split("\n\n")[0])
        directive = payload["chapter_directive"]
        assert directive == _DIRECTIVE
        for marker in _CARD_LEAK_MARKERS:
            assert marker not in directive, f"directive leaked card marker {marker!r}"
        # 知识 line: the card reaches the Writer on its own, separate line.
        card = payload["characters"][0]
        assert card["id"] == char_id
        assert card["frozen_fields"]["core_traits"] == "谨慎"
        # author_notes is on the card line, NOT on the directive line.
        assert card["author_notes"]["motivation"] == "为妹妹复仇"
        assert "为妹妹复仇" not in directive

    # ----- INV-4 (P3): Context Pack selects only the involved card, not dump-all.
    # (Only 林夕 is involved; add a decoy character to prove non-involved cards are
    # NOT pulled into the involved slice. Re-run one chapter with the decoy — this
    # is chapter 6 now that the closed loop above already occupies 1-5.)
    decoy = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "路人", "role": "群演", "frozen_fields": {}, "live_fields": {}},
    ).json()
    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        _run_chapter(client, auth_headers, book["id"], 6)
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()

    last_writer_user = writer_llm.users[-1]
    last_payload = json.loads(last_writer_user.split("\n\n")[0])
    involved_card_ids = [c["id"] for c in last_payload["characters"]]
    # The Writer's 知识 line is the involved subset only — the decoy群演 (not
    # involved) is NOT pulled in. P3: relevant cards, not dump-all.
    assert decoy["id"] not in involved_card_ids
    assert char_id in involved_card_ids
    # The Expander's relevant-memory slice is also involved-only (its all_characters
    # pool sees both, but involved_characters does not include the decoy).
    last_exp_ctx = expander_llm.contexts[-1]
    assert decoy["id"] not in [c["id"] for c in last_exp_ctx["involved_characters"]]
    assert decoy["id"] in [c["id"] for c in last_exp_ctx["all_characters"]]

    # ----- INV-1'' headline tier, genuinely penetrated (审后教训, KK 🟡4):
    #       by chapter 6 (6 finalized chapters exist for THIS context: 1-5),
    #       the fulltext window (3) covers {3,4,5}, the (test-patched)
    #       full-summary window (1) covers {2}, and chapter 1 is finally
    #       older than BOTH — it must appear ONLY in recent_headlines, never
    #       in recent_fulltext or recent_summaries. This is not a
    #       `continue`-shaped no-op: the assertions below actively require a
    #       non-empty headline entry to exist and be well-formed.
    _assert_three_tier_invariants(6)
    last_headlines = last_exp_ctx.get("recent_headlines", [])
    assert len(last_headlines) >= 1, "expected the headline tier to have been reached by chapter 6"
    assert [h["index"] for h in last_headlines] == [1], "ch1 should be the sole headline-tier entry at ch6"
    ch1_summary = chapters[0]["summary"]  # chapters[0] is chapter index 1's finalized dict
    ch1_headline = last_headlines[0]["headline"]
    # Red line ("不发明情节"): the headline is exactly the mechanical
    # distillation of the Extractor's own summary — never fresh content.
    assert ch1_headline == _distill_headline(ch1_summary)
    assert len(ch1_headline) <= HEADLINE_MAX_CHARS + 1
    stripped = ch1_headline[:-1] if ch1_headline.endswith("…") else ch1_headline
    assert ch1_summary.startswith(stripped), "headline must be a literal prefix of its source summary"
    # And the mid-body marker (buried deep in ch1's full draft_text) must
    # never leak via the headline — it's derived from summary, not the body.
    assert "【正文核心_1_MIDMARKER】" not in ch1_headline

    # ----- INV-5 (P2): the timeline is append-only — all 6 chapters' events
    #       coexist; chapter N's extraction never wiped chapter N-1's. -----------
    timeline = client.get(
        f"/api/v1/characters/{char_id}/timeline", headers=auth_headers
    ).json()["items"]
    texts = {e["event_text"] for e in timeline}
    assert {
        "事件@第1章", "事件@第2章", "事件@第3章", "事件@第4章", "事件@第5章", "事件@第6章",
    } <= texts
    assert len(timeline) == 6  # no chapter clobbered another's event

    # The rolled-forward live_fields reflects the LATEST chapter (memory advanced).
    final_card = client.get(f"/api/v1/characters/{char_id}", headers=auth_headers).json()
    assert final_card["live_fields"]["current_status"] == "走到第6章末"

    # ----- INV-6: one closed loop logged all three agents. ---------------------
    logs = client.get("/api/v1/admin/logs?limit=200", headers=auth_headers).json()["items"]
    agent_names = {log["agent_name"] for log in logs}
    assert {"expander", "writer", "extractor"} <= agent_names
    # And every agent fired once per chapter (6 chapters total).
    for role in ("expander", "writer", "extractor"):
        role_logs = client.get(
            f"/api/v1/admin/logs?agent_name={role}&limit=200", headers=auth_headers
        ).json()["items"]
        # 6 chapters were run end-to-end; each agent logged 6 successful calls.
        assert len([log for log in role_logs if log["error"] is None]) == 6, role


def test_memory_rolls_forward_expander_locates_by_memory_not_pointer(client, auth_headers):
    """Tighter focus on the 'memory rolls + the optimizer locates itself via
    memory, no position pointer' claim (P4): at expand time the Expander locates
    "where the story is" purely from structured memory (recent_summaries /
    recent_fulltext of finalized chapters), with NO per-chapter outline
    cursor/pointer field, and NO whole-book outline input at all (deleted with
    the outline module — v1.3.0 JJ P4/P5/P8).

    v1.3.1 (KK) P7: with only 1 prior finalized chapter (< RECENT_FULLTEXT_
    COUNT=3), chapter 1's write-back lands in the FULLTEXT window
    (``recent_fulltext``), not ``recent_summaries`` — this is the correct,
    intentional two-tier behaviour (small, recent memory is bounded fulltext;
    only chapters OLDER than the window degrade to summary-only)."""
    expander_llm = _RecordingExpanderLLM()
    writer_llm = _RecordingWriterLLM()
    extractor_llm = _RecordingExtractorLLM()
    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        book, character = _seed_book_with_card(client, auth_headers)
        _run_chapter(client, auth_headers, book["id"], 1)
        _run_chapter(client, auth_headers, book["id"], 2)
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()

    ch2_ctx = expander_llm.contexts[1]
    # The story progressed: chapter 1's write-back is visible to chapter 2's
    # 优化师 — this is how it knows "已发生哪些节拍". Since only 1 finalized
    # chapter exists (inside the RECENT_FULLTEXT_COUNT=3 window), it surfaces
    # via recent_fulltext (full draft_text), not recent_summaries — proving
    # the bounded-recent-window channel IS a legitimate locating signal, not
    # just the summary tail. At expand time the chapter has no
    # structured_prompt yet, so involved_characters is empty by design
    # (§4.1) — the locating signal is memory (fulltext/summaries), NOT a
    # pre-populated involved slice.
    fulltext = ch2_ctx.get("recent_fulltext", [])
    assert any(c.get("index") == 1 for c in fulltext), "ch2 expander did not see ch1 via recent_fulltext"
    assert ch2_ctx.get("recent_summaries", []) == []  # ch1 is inside the fulltext window, not the summary tail.
    assert ch2_ctx.get("recent_headlines", []) == []  # a fortiori — nothing has aged past the summary tier either.
    assert ch2_ctx["involved_characters"] == []  # not yet expanded — by design
    # No whole-book outline input at all (P4: deleted with the outline module).
    assert "outline" not in ch2_ctx
    # No position-pointer / cursor field anywhere — locating is implicit (P4).
    for banned in (
        "current_position",
        "position_pointer",
        "cursor",
        "outline_cursor",
        "next_beat",
        "outline_slice",
    ):
        assert banned not in ch2_ctx

    # And the WRITER for chapter 2 DOES carry the rolled-forward memory on the
    # 知识 line (the involved card's updated live_fields), proving the loop's
    # memory genuinely advanced between chapters.
    ch2_writer_payload = json.loads(writer_llm.users[1].split("\n\n")[0])
    assert ch2_writer_payload["characters"][0]["live_fields"]["current_status"] == "走到第1章末"
