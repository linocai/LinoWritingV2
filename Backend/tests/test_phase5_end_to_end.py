from __future__ import annotations

# v1.0.0 EE Phase 5 (archive/v1.0.0_plan.md §7-Phase 5) — link-up 联调 +
# architecture-invariant verification.
#
# This is NOT the real 100-chapter LLM long run (that is a user-side, real-key,
# real-device task per §D7). Here we drive the FULL HTTP chain end-to-end with
# *mock* LLMs that RECORD the context each agent receives, then assert — over a
# rolling, multi-chapter run — that the architecture red lines hold:
#
#   闭环 (closed loop):
#     ingest outline (+ author initial cards) → create chapter →
#     expand (优化师 just-in-time reads WHOLE outline + relevant memory, emits
#     chapter_directive) → write (Writer uses directive + cards/timelines) →
#     finalize (档案员 writes back structured memory) → next chapter, whose
#     expander/writer context can read the PREVIOUS chapter's written-back
#     memory (proves memory rolls + the story advances without a position
#     pointer).
#
#   不变量 (invariants), asserted across ≥3 chapters:
#     INV-1  (P2) chapter N (N≥2) Writer/Expander context contains NONE of the
#            previous chapters' draft_text — only relevant cards + timeline +
#            the WHOLE outline. Memory IS the structured compression of "前文".
#     INV-2  (P4) the Expander context carries the WHOLE outline raw_text and
#            NO pre-sliced per-chapter 章纲 key — it locates itself purely by
#            memory (no position pointer).
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
    get_expander_llm_client,
    get_extractor_llm_client,
    get_writer_llm_client,
)
from app.main import app
from tests.conftest import MockLLMClient

# A realistic ~5000-字 plain-prose outline (whole-thing injected verbatim).
# Built from a distinctive sentinel so we can assert it arrives unsliced.
_OUTLINE = "【全书大纲】" + ("雨城三部曲，从林夕追查妹妹失踪写到揭开旧案真相。" * 60)

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
from app.services.context_pack import (  # noqa: E402
    STYLE_SAMPLES_CHAPTER_COUNT,
    STYLE_SAMPLES_CHARS_PER_SIDE,
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
        yield _chapter_body(idx)


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


def _seed_book_with_outline_and_card(client, auth_headers) -> tuple[dict, dict]:
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "雨城三部曲", "cover_color": "#111111", "style_directive": "克制"},
    ).json()
    # Author imports the outline (no LLM, always succeeds).
    r = client.post(
        f"/api/v1/books/{book['id']}/outline/ingest",
        headers=auth_headers,
        json={"raw_text": _OUTLINE},
    )
    assert r.status_code == 200, r.text
    # Author imports the initial character card (NOT generated from the outline).
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
# The end-to-end closed-loop test — 3 chapters, all invariants.
# --------------------------------------------------------------------------


def test_end_to_end_three_chapter_closed_loop_holds_all_invariants(client, auth_headers):
    expander_llm = _RecordingExpanderLLM()
    writer_llm = _RecordingWriterLLM()
    extractor_llm = _RecordingExtractorLLM()

    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        book, character = _seed_book_with_outline_and_card(client, auth_headers)

        chapters = [_run_chapter(client, auth_headers, book["id"], i) for i in (1, 2, 3)]
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()

    # The loop actually ran 3 chapters to finalized.
    assert [c["status"] for c in chapters] == ["finalized"] * 3
    assert len(expander_llm.contexts) == 3
    assert len(writer_llm.users) == 3
    assert len(extractor_llm.contexts) == 3

    char_id = character["id"]

    # ----- INV-2 (P4): every Expander context has the WHOLE outline raw_text and
    #       NO pre-sliced per-chapter 章纲 key. ------------------------------------
    for ctx in expander_llm.contexts:
        assert ctx["outline"] == _OUTLINE  # whole, verbatim — not sliced
        for banned in ("outline_slice", "chapter_outline", "arc_beats", "presliced_outline"):
            assert banned not in ctx
        # No position pointer key smuggled in.
        serialized = json.dumps(ctx, ensure_ascii=False, default=str)
        assert "outline_slice" not in serialized

    # ----- INV-1 (P2): chapter N (N≥2) Expander/Writer context never carries any
    #       previous chapter's FULL body. "前文" reaches the agents ONLY as
    #       structured memory (summaries / timeline / live_fields), never as
    #       re-fed prior prose. -----------------------------------------------------
    for n in (2, 3):
        exp_ctx = expander_llm.contexts[n - 1]
        wri_user = writer_llm.users[n - 1]
        serialized_exp = json.dumps(exp_ctx, ensure_ascii=False, default=str)
        for earlier in range(1, n):
            marker = f"【正文核心_{earlier}_MIDMARKER】"
            # The mid-body marker (outside the bounded head/tail style window)
            # must appear NOWHERE — neither expander nor writer context re-feeds
            # the prior chapter's full body.
            assert marker not in serialized_exp, f"ch{n} expander ctx leaked ch{earlier} full body"
            assert marker not in wri_user, f"ch{n} writer ctx leaked ch{earlier} full body"

    # Positive (memory rolls — the optimizer locates itself via memory, P4):
    # chapter 2/3's Expander sees the PRIOR chapter's write-back via
    # recent_summaries (a finalized chapter's summary), not via re-fed prose.
    for n in (2, 3):
        exp_ctx = expander_llm.contexts[n - 1]
        summaries = exp_ctx.get("recent_summaries", [])
        assert any(
            f"第{n - 1}章摘要" in (s.get("summary") or "") for s in summaries
        ), f"ch{n} expander did not see ch{n - 1}'s written-back summary"

    # Positive (memory rolls — Writer side): chapter 2/3's Writer sees the
    # rolled-forward memory on the 知识 line — the involved card's updated
    # live_fields + the prior chapter's timeline event — never the prior body.
    for n in (2, 3):
        payload = json.loads(writer_llm.users[n - 1].split("\n\n")[0])
        timelines = payload.get("timelines", {})
        events = timelines.get(char_id, [])
        event_texts = {e["event_text"] for e in events}
        assert f"事件@第{n - 1}章" in event_texts, f"ch{n} writer missing ch{n - 1}'s timeline"
        card_status = payload["characters"][0]["live_fields"]["current_status"]
        assert card_status == f"走到第{n - 1}章末", f"ch{n} writer card not rolled forward"

    # INV-1b (P2 at scale): the only prior-prose channel (style_samples) is
    # BOUNDED — at most STYLE_SAMPLES_CHAPTER_COUNT recent chapters, head+tail
    # capped — so it does NOT grow with chapter count. This is the structural
    # reason "永不把前 99 章正文喂回去" holds. By chapter 3, three finalized
    # chapters exist, yet the Writer only ever sees ≤2 in style_samples.
    last_writer_payload = json.loads(writer_llm.users[-1].split("\n\n")[0])
    style_samples = last_writer_payload.get("style_samples", [])
    assert len(style_samples) <= STYLE_SAMPLES_CHAPTER_COUNT
    for sample in style_samples:
        assert len(sample.get("head", "")) <= STYLE_SAMPLES_CHARS_PER_SIDE
        assert len(sample.get("tail", "")) <= STYLE_SAMPLES_CHARS_PER_SIDE
        # And even these bounded snippets never carry the mid-body marker.
        assert "MIDMARKER" not in sample.get("head", "")
        assert "MIDMARKER" not in sample.get("tail", "")

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
    # NOT pulled into the involved slice. Re-run one chapter with the decoy.)
    decoy = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "路人", "role": "群演", "frozen_fields": {}, "live_fields": {}},
    ).json()
    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        _run_chapter(client, auth_headers, book["id"], 4)
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

    # ----- INV-5 (P2): the timeline is append-only — all 4 chapters' events
    #       coexist; chapter N's extraction never wiped chapter N-1's. -----------
    timeline = client.get(
        f"/api/v1/characters/{char_id}/timeline", headers=auth_headers
    ).json()["items"]
    texts = {e["event_text"] for e in timeline}
    assert {"事件@第1章", "事件@第2章", "事件@第3章", "事件@第4章"} <= texts
    assert len(timeline) == 4  # no chapter clobbered another's event

    # The rolled-forward live_fields reflects the LATEST chapter (memory advanced).
    final_card = client.get(f"/api/v1/characters/{char_id}", headers=auth_headers).json()
    assert final_card["live_fields"]["current_status"] == "走到第4章末"

    # ----- INV-6: one closed loop logged all three agents. ---------------------
    logs = client.get("/api/v1/admin/logs?limit=200", headers=auth_headers).json()["items"]
    agent_names = {log["agent_name"] for log in logs}
    assert {"expander", "writer", "extractor"} <= agent_names
    # And every agent fired once per chapter (4 chapters total).
    for role in ("expander", "writer", "extractor"):
        role_logs = client.get(
            f"/api/v1/admin/logs?agent_name={role}&limit=200", headers=auth_headers
        ).json()["items"]
        # 4 chapters were run end-to-end; each agent logged 4 successful calls.
        assert len([log for log in role_logs if log["error"] is None]) == 4, role


def test_memory_rolls_forward_expander_locates_by_memory_not_pointer(client, auth_headers):
    """Tighter focus on the 'memory rolls + the optimizer locates itself via
    memory, no position pointer' claim (P4): at expand time the Expander locates
    "where the story is" purely from structured memory (recent_summaries of
    finalized chapters), with NO per-chapter outline cursor/pointer field, and
    the WHOLE outline is the only forward-looking plan it reads."""
    expander_llm = _RecordingExpanderLLM()
    writer_llm = _RecordingWriterLLM()
    extractor_llm = _RecordingExtractorLLM()
    app.dependency_overrides[get_expander_llm_client] = lambda: expander_llm
    app.dependency_overrides[get_writer_llm_client] = lambda: writer_llm
    app.dependency_overrides[get_extractor_llm_client] = lambda: extractor_llm
    try:
        book, character = _seed_book_with_outline_and_card(client, auth_headers)
        _run_chapter(client, auth_headers, book["id"], 1)
        _run_chapter(client, auth_headers, book["id"], 2)
    finally:
        app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
        app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()

    ch2_ctx = expander_llm.contexts[1]
    # The story progressed: chapter 1's write-back (recent_summaries) is visible
    # to chapter 2's 优化师 — this is how it knows "已发生哪些节拍". At expand
    # time the chapter has no structured_prompt yet, so involved_characters is
    # empty by design (§4.1) — the locating signal is recent_summaries + the
    # whole outline, NOT a pre-populated involved slice.
    summaries = ch2_ctx.get("recent_summaries", [])
    assert any("第1章摘要" in (s.get("summary") or "") for s in summaries)
    assert ch2_ctx["involved_characters"] == []  # not yet expanded — by design
    # The WHOLE outline is the forward-looking plan (P4).
    assert ch2_ctx["outline"] == _OUTLINE
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
