from __future__ import annotations

from sqlalchemy import event

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent
from app.services.context_pack import (
    build_expander_context,
    build_extractor_context,
    build_writer_context,
)


def test_context_pack_filters_characters_and_limits_summaries(db_session):
    """v1.3.1 (KK) P7: these 3 finalized chapters have NO draft_text (empty
    body), so none of them can land in ``recent_fulltext`` — they all fall
    through to ``recent_summaries`` (which is unbounded for anything older
    than the fulltext window, and the fulltext window here is empty since
    there's no prose to carry). See
    ``test_recent_fulltext_and_summaries_split_by_window`` below for the
    two-tier split when draft_text IS present."""
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()

    c1 = Character(book_id=book.id, name="林夕", role="主角", frozen_fields={"core_traits": "谨慎"}, live_fields={})
    c2 = Character(book_id=book.id, name="黑刀", role="反派", frozen_fields={"core_traits": "沉默"}, live_fields={})
    db_session.add_all([c1, c2])
    db_session.flush()

    chapter1 = Chapter(book_id=book.id, index=1, user_prompt="一", summary="第一章摘要", status="finalized")
    chapter2 = Chapter(book_id=book.id, index=2, user_prompt="二", summary="第二章摘要", status="finalized")
    chapter3 = Chapter(book_id=book.id, index=3, user_prompt="三", summary="第三章摘要", status="finalized")
    chapter4 = Chapter(
        book_id=book.id,
        index=4,
        user_prompt="四",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": [c1.id]},
    )
    db_session.add_all([chapter1, chapter2, chapter3, chapter4])
    db_session.flush()
    db_session.add(
        TimelineEvent(
            book_id=book.id,
            character_id=c1.id,
            chapter_id=chapter2.id,
            event_type="action",
            event_text="发现旧信。",
        )
    )
    db_session.commit()

    expander = build_expander_context(db_session, book, chapter4)
    assert expander["recent_fulltext"] == []
    assert [item["index"] for item in expander["recent_summaries"]] == [1, 2, 3]
    assert {item["id"] for item in expander["all_characters"]} == {c1.id, c2.id}

    writer = build_writer_context(db_session, book, chapter4)
    assert [character["id"] for character in writer["characters"]] == [c1.id]
    assert list(writer["timelines"].keys()) == [c1.id]
    assert writer["timelines"][c1.id][0]["event_text"] == "发现旧信。"


def test_recent_fulltext_and_summaries_split_by_window(db_session):
    """v1.3.1 (KK) P7 — the two-tier split: with draft_text present, the
    nearest RECENT_FULLTEXT_COUNT (3) finalized chapters land in
    recent_fulltext (full draft_text), everything older is summary-only."""
    from app.services.context_pack import RECENT_FULLTEXT_COUNT

    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()
    c1 = Character(book_id=book.id, name="林夕", role="主角", frozen_fields={}, live_fields={})
    db_session.add(c1)
    db_session.flush()

    for i in range(1, 6):  # 5 finalized chapters, all with draft_text.
        db_session.add(
            Chapter(
                book_id=book.id,
                index=i,
                user_prompt=f"第{i}章",
                draft_text=f"第{i}章正文。" * 50,
                summary=f"第{i}章摘要",
                status="finalized",
            )
        )
    current = Chapter(
        book_id=book.id,
        index=6,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": [c1.id]},
    )
    db_session.add(current)
    db_session.commit()

    expander = build_expander_context(db_session, book, current)
    assert len(expander["recent_fulltext"]) == RECENT_FULLTEXT_COUNT == 3
    assert [c["index"] for c in expander["recent_fulltext"]] == [3, 4, 5]
    assert all(c["draft_text"] for c in expander["recent_fulltext"])
    assert [s["index"] for s in expander["recent_summaries"]] == [1, 2]

    writer = build_writer_context(db_session, book, current)
    assert [c["index"] for c in writer["recent_fulltext"]] == [3, 4, 5]
    assert [s["index"] for s in writer["recent_summaries"]] == [1, 2]
    # style_samples zeroed — the fulltext window already carries these chapters.
    assert writer["style_samples"] == []


# ---- Phase L-2 (§5.L) — author_notes gating + merged query ----------------


def _seed_with_author_notes(db_session) -> tuple[Book, Character, Chapter]:
    """Two finalized chapters + one current; character has author_notes."""
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()
    character = Character(
        book_id=book.id,
        name="林夕",
        role="主角",
        frozen_fields={"core_traits": "谨慎"},
        live_fields={"current_status": "山中"},
        author_notes={"motivation": "为妹妹复仇", "secret": "童年纵火"},
    )
    db_session.add(character)
    db_session.flush()
    db_session.add_all([
        Chapter(
            book_id=book.id,
            index=1,
            user_prompt="一",
            draft_text="第一章正文。" * 100,
            summary="第一章摘要",
            status="finalized",
            source="agent",
        ),
        Chapter(
            book_id=book.id,
            index=2,
            user_prompt="二",
            draft_text="第二章正文。" * 100,
            summary="第二章摘要",
            status="finalized",
            source="agent",
        ),
    ])
    current = Chapter(
        book_id=book.id,
        index=3,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": [character.id]},
    )
    db_session.add(current)
    db_session.commit()
    return book, character, current


def test_writer_context_includes_author_notes(db_session):
    """§5.L decision: Writer gets author_notes for backstage understanding."""
    book, character, current = _seed_with_author_notes(db_session)
    ctx = build_writer_context(db_session, book, current)
    assert len(ctx["characters"]) == 1
    payload = ctx["characters"][0]
    assert payload["author_notes"] == {"motivation": "为妹妹复仇", "secret": "童年纵火"}


def test_expander_context_includes_author_notes(db_session):
    """§5.L.4 decision: Expander reads author_notes when inferring focus_traits.

    Expander uses ``_character_brief`` (not _character_full) for the
    ``all_characters`` slot, so verify the brief carries enough hint —
    OR if the brief stays minimal, the design must surface author_notes
    elsewhere. Current implementation: brief stays terse; author_notes
    in Expander flows via the schema slot the Writer also sees. Since
    L-2 plan calls for Expander to "see" author_notes when picking
    focus_traits, we surface it on the brief too.
    """
    book, character, current = _seed_with_author_notes(db_session)
    ctx = build_expander_context(db_session, book, current)
    # Today the brief is intentionally minimal (id/name/role/profile).
    # The Expander gets author_notes through the LLM's view of the
    # context dict if it's surfaced. Per §5.L.4 we route author_notes
    # via the brief's author_notes field.
    brief = ctx["all_characters"][0]
    assert "author_notes" in brief
    assert brief["author_notes"] == {"motivation": "为妹妹复仇", "secret": "童年纵火"}


def test_extractor_context_omits_author_notes(db_session):
    """§5.L decision: Extractor must NOT see author_notes (private channel)."""
    book, character, current = _seed_with_author_notes(db_session)
    ctx = build_extractor_context(db_session, book, current)
    assert len(ctx["characters"]) == 1
    payload = ctx["characters"][0]
    assert "author_notes" not in payload
    # Defensive: the other fields are still there.
    assert payload["frozen_fields"] == {"core_traits": "谨慎"}
    assert payload["live_fields"] == {"current_status": "山中"}


def test_writer_context_fulltext_and_style_window_share_one_bounded_query(db_session):
    """§5.L + audit J merged the old ``_recent_summaries`` / ``_style_samples``
    pair into one bounded-window SELECT. v1.3.1 (KK) P7 keeps that merge for
    the bounded window (recent_fulltext + style_samples share one query), and
    adds a SECOND, deliberately separate query for the unbounded
    ``recent_summaries`` tail (everything older than the window) — a single
    ``LIMIT``-based query structurally cannot serve both "bounded window" and
    "no upper bound" at once. So the contract here is: at most 2 chapter-only
    SELECTs total (bounded window + unbounded tail), never more; and the
    2-chapter book of ``_seed_with_author_notes`` fits entirely inside the
    fulltext window, so the unbounded tail is empty (0 results, but the query
    still fires — see the follow-up test below for a body that only fires the
    window query).
    """
    book, character, current = _seed_with_author_notes(db_session)

    chapter_selects: list[str] = []

    def _capture(conn, cursor, statement, params, context, executemany):
        # Normalize for SQLite case + whitespace.
        s = " ".join(statement.split()).lower()
        if s.startswith("select") and "from chapters" in s and "where chapters.book_id" in s:
            # Distinguish the timeline-join SELECT (it has 'join chapters'
            # not 'from chapters') from chapter-only SELECTs.
            chapter_selects.append(s)

    bind = db_session.get_bind()
    event.listen(bind, "before_cursor_execute", _capture)
    try:
        ctx = build_writer_context(db_session, book, current)
    finally:
        event.remove(bind, "before_cursor_execute", _capture)

    # Both finalized chapters here fit inside the fulltext window
    # (RECENT_FULLTEXT_COUNT=3 >= 2), so recent_fulltext carries both and
    # recent_summaries/style_samples are empty (style_samples zeroed by the
    # anti-duplication rule since the fulltext window hit).
    assert [c["index"] for c in ctx["recent_fulltext"]] == [1, 2]
    assert ctx["recent_summaries"] == []
    assert ctx["style_samples"] == []

    # At most 2 chapter-only SELECTs (bounded window + unbounded tail) — never
    # a 3rd, and never back to the pre-merge shape of 2 *bounded* SELECTs.
    chapter_only_selects = [s for s in chapter_selects if "join" not in s.split("from chapters")[1].split("where")[0]]
    assert len(chapter_only_selects) <= 2, (
        f"expected at most 2 chapters SELECTs (bounded window + unbounded "
        f"tail), got {len(chapter_only_selects)}: {chapter_only_selects!r}"
    )


def test_merged_query_respects_different_limits(db_session):
    """v1.3.1 (KK) P7: ``fulltext_limit`` and ``style_samples_limit`` can
    diverge — the bounded-window fetch must be ``max(...)`` of the two, and
    each of ``recent_fulltext`` / ``style_samples`` trimmed independently
    from that shared window. ``recent_summaries`` (unbounded tail, older than
    the window) is verified separately since it no longer takes a limit."""
    book = Book(title="x")
    db_session.add(book)
    db_session.flush()
    # Five finalized chapters, each with summary + draft_text.
    for i in range(1, 6):
        db_session.add(
            Chapter(
                book_id=book.id,
                index=i,
                user_prompt=f"第{i}章",
                draft_text=f"第{i}章正文。" * 100,
                summary=f"第{i}章摘要",
                status="finalized",
                source="agent",
            )
        )
    current = Chapter(
        book_id=book.id,
        index=6,
        user_prompt="当前",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "x", "characters_involved": []},
    )
    db_session.add(current)
    db_session.commit()

    from app.services.context_pack import _recent_finalized

    # fulltext=2, samples=4 → shared window fetches 4, fulltext trims to 2;
    # everything outside the 4-row window (chapters 1) becomes the unbounded
    # summaries tail.
    fulltext, summaries, samples = _recent_finalized(
        db_session, book.id, 6, fulltext_limit=2, style_samples_limit=4
    )
    assert len(fulltext) == 2
    assert [c["index"] for c in fulltext] == [4, 5]
    assert len(samples) == 4
    assert [s["chapter_index"] for s in samples] == [2, 3, 4, 5]
    assert [s["index"] for s in summaries] == [1]

    # Reverse skew: fulltext=3, samples=1 → shared window fetches 3.
    fulltext, summaries, samples = _recent_finalized(
        db_session, book.id, 6, fulltext_limit=3, style_samples_limit=1
    )
    assert [c["index"] for c in fulltext] == [3, 4, 5]
    assert [s["chapter_index"] for s in samples] == [5]
    assert [s["index"] for s in summaries] == [1, 2]

    # Both zero → empty + no DB hit (we don't assert the latter explicitly).
    fulltext, summaries, samples = _recent_finalized(
        db_session, book.id, 6, fulltext_limit=0, style_samples_limit=0
    )
    assert fulltext == [] and summaries == [] and samples == []
