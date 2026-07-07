from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent

# Style-sample knobs for WriterAgent's "参考前文文风" block.
# Both agent-written and imported finalized chapters feed this — the goal is
# pure stylistic reference, regardless of how the chapter was produced.
#
# v1.3.1 (KK) P7 审后修复 🔵1 (reviewer 抓出): this channel is currently
# UNREACHABLE with a non-empty result in ``build_writer_context`` — NOT just
# "a fallback for very-early books" as an earlier comment here incorrectly
# claimed. ``_recent_finalized``'s ``fulltext_rows`` and ``style_rows`` are
# both filtered from the SAME ``windowed_rows`` by the SAME condition
# (``chapter.draft_text or ""`` truthy) — so ``style_rows`` non-empty implies
# ``fulltext_rows`` non-empty too, which means ``build_writer_context``
# always zeroes ``style_samples`` right back out (see the
# ``if recent_fulltext: style_samples = []`` line below). This holds even for
# a book's very first finalized chapter (1 chapter is enough to populate
# ``recent_fulltext``, well under the ``RECENT_FULLTEXT_COUNT=3`` cap) — there
# is no chapter count at which the fallback fires with non-empty output.
# ``WriterAgent``'s "# 参考前文文风" block wording and
# ``_render_style_samples_block`` are consequently dead in production too
# (still reachable directly in unit tests that call ``_recent_finalized``
# with ``fulltext_limit=0``, which is why they're kept rather than deleted).
# Per PROJECT_PLAN §4 P7, "整体退场" (fully retiring the channel) was an
# allowed option; this pass keeps the mechanism in place (plan-compliant,
# behavior-preserving) and only corrects the comment to describe reality —
# removing the dead code/mechanism outright is a slightly larger change than
# a doc-only fix and is left as a follow-up if the team wants to formally
# retire the channel rather than leave it inert.
STYLE_SAMPLES_CHAPTER_COUNT = 2
STYLE_SAMPLES_CHARS_PER_SIDE = 400

# v1.3.1 (KK) P7 — two-tier memory: the most recent ``RECENT_FULLTEXT_COUNT``
# finalized chapters are fed to Expander/Writer as FULL ``draft_text`` (原文);
# every finalized chapter older than that is fed as ``summary`` only, with NO
# upper bound (replaces the old ``RECENT_SUMMARIES_COUNT=2`` cap — v0.7 §5.L).
# New invariant (locked, see test_phase5_end_to_end.py INV-1'/INV-1b'): the
# fulltext channel is bounded at exactly this constant regardless of total
# chapter count; only summaries (~200 字 each) grow linearly, which is
# acceptable up to ~300 chapters (see PROJECT_PLAN §4 P7 / Backlog §3.1 for
# the super-long-form third memory tier, not built here).
RECENT_FULLTEXT_COUNT = 3


def build_expander_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    # v1.3.0 (II/JJ) P4 — 去大纲化: the Expander's job is now "read already-
    # finished chapter summaries + the author's this-chapter narrative,
    # structure it + check continuity + distill a directive" (no more whole-
    # book outline input). Assembled just-in-time from:
    #   ① persona — injected as the system prompt (not here), DB-stored.
    #   ② relevant memory slice — involved cards + their recent timeline (via
    #      the existing ``characters_involved`` selection, NOT dump-all — P3) +
    #      ``recent_summaries`` (已完成章梗概, dynamic, written back by the
    #      Extractor). This is what continuity-checking is now grounded in
    #      (replaces the old whole-outline read).
    #   ③ author intent — ``chapter.user_prompt`` (now a full narrative
    #      paragraph describing what happens this chapter, not a one-liner —
    #      see P7's Step1 copy change; the key/shape here is unchanged).
    # ``all_characters`` (brief, with frozen_fields + author_notes) is kept so
    # the Expander can still pick characters_involved / infer focus_traits
    # (§5.L.4) even on the first pass when the involved set is still empty.
    #
    # v1.3.1 (KK) P7 — two-tier memory: the nearest ``RECENT_FULLTEXT_COUNT``
    # finalized chapters are read as full ``draft_text`` (``recent_fulltext``);
    # everything older is ``summary``-only (``recent_summaries``, no upper
    # bound). The Expander's continuity check now grounds itself in both.
    recent_fulltext, summaries, _ = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=RECENT_FULLTEXT_COUNT,
        style_samples_limit=0,
    )
    structured_prompt = chapter.structured_prompt or {}
    involved_ids = structured_prompt.get("characters_involved") or []
    characters = _book_characters(db, book.id)
    involved = [character for character in characters if character.id in involved_ids]
    involved_timelines = {
        character.id: _character_timeline(db, book.id, character.id, limit=15)
        for character in involved
    }
    return {
        "book": {
            "id": book.id,
            "title": book.title,
            "world_setting": book.world_setting,
            "style_directive": book.style_directive,
        },
        "chapter": {
            "id": chapter.id,
            "index": chapter.index,
            "title": chapter.title,
            "user_prompt": chapter.user_prompt,
        },
        # relevant memory slice: involved cards + their recent timeline.
        "involved_characters": [
            _character_full(character, include_author_notes=True) for character in involved
        ],
        "involved_timelines": involved_timelines,
        # 两层记忆 (P7): nearest RECENT_FULLTEXT_COUNT finalized chapters as full
        # draft_text, everything older as summary-only (unbounded).
        "recent_fulltext": recent_fulltext,
        "recent_summaries": summaries,
        "all_characters": [_character_brief(character) for character in characters],
    }


def build_writer_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    # v1.0.0 EE Phase 3 (§4.2) — the Writer reads along TWO distinct lines (P1
    # 红线, "两条线分明"):
    #   · 方向 (direction): ``chapter_directive`` — the Expander's 200-300 字
    #     steering, surfaced as a TOP-LEVEL key (lifted out of structured_prompt)
    #     so it reads as its own input, not buried inside the blueprint JSON.
    #   · 知识 (knowledge): ``characters`` / ``timelines`` / ``style_samples`` —
    #     the relevant cards + memory, delivered by Context Pack on the same
    #     separate line they always were. The directive NEVER carries this
    #     knowledge (the Expander is forbidden from copying cards into it); it
    #     only points the Writer where to go.
    # The directive degrades gracefully: old / un-expanded chapters have no
    # ``chapter_directive`` in their structured_prompt → ``None`` here, and the
    # Writer simply falls back to the structured_prompt blueprint (the pre-P3
    # behaviour). Never raises.
    structured_prompt = chapter.structured_prompt or {}
    involved_ids = structured_prompt.get("characters_involved") or []
    characters = _book_characters(db, book.id)
    selected = [character for character in characters if character.id in involved_ids]
    timelines = {character.id: _character_timeline(db, book.id, character.id, limit=15) for character in selected}
    # Merged query (§5.L + audit J): fulltext/summaries + style_samples used to
    # fire multiple near-identical SELECTs against the chapters table; now they
    # share one query and split in memory.
    #
    # v1.3.1 (KK) P7 — two-tier memory: nearest RECENT_FULLTEXT_COUNT finalized
    # chapters as full draft_text (``recent_fulltext``), older ones as
    # summary-only (``recent_summaries``, unbounded). style_samples's own
    # query still runs (see ``_recent_finalized``), but its result is
    # unconditionally discarded below whenever ``recent_fulltext`` is
    # non-empty — feeding the same chapters twice (once as fulltext, once as
    # head/tail snippets) would be duplicate token spend for identical text.
    #
    # v1.3.1 (KK) P7 审后修复 🔵1 (reviewer 抓出): an earlier version of this
    # comment described style_samples as "populated as a fallback for
    # very-early books where the fulltext window is still empty" — that is
    # FALSE. ``fulltext_rows``/``style_rows`` share the same source rows and
    # the same non-empty-``draft_text`` filter (see ``_recent_finalized``), so
    # ``style_samples`` can only be non-empty when ``recent_fulltext`` is ALSO
    # non-empty — meaning the zero-out below fires unconditionally whenever
    # there would be anything to zero. There is no chapter count (not even
    # "1 finalized chapter, well under RECENT_FULLTEXT_COUNT=3") at which
    # this fallback actually delivers a non-empty result to the Writer.
    # ``style_samples`` is kept as a mechanism (plan allowed either retiring
    # it entirely or keeping it inert; see STYLE_SAMPLES_CHAPTER_COUNT's
    # docstring above for why outright removal is left as a follow-up) rather
    # than a live code path.
    recent_fulltext, summaries, style_samples = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=RECENT_FULLTEXT_COUNT,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        chars_per_side=STYLE_SAMPLES_CHARS_PER_SIDE,
    )
    if recent_fulltext:
        style_samples = []
    # 方向 line: lift chapter_directive out so it's its own top-level input.
    # ``None`` (or empty/whitespace) means "no directive" — graceful degrade.
    raw_directive = structured_prompt.get("chapter_directive")
    chapter_directive = (
        raw_directive.strip()
        if isinstance(raw_directive, str) and raw_directive.strip()
        else None
    )
    return {
        "world_setting": book.world_setting or "",
        "style_directive": book.style_directive or "",
        # 方向 (steering) — the Expander's directive, its own line.
        "chapter_directive": chapter_directive,
        "structured_prompt": structured_prompt,
        # 知识 (knowledge) — Writer reads author_notes for backstage
        # understanding (§5.L.5); the system_prompt forbids narrating it
        # directly, so feeding it is safe and lets the model judge "what
        # would this character do here".
        "characters": [_character_full(character, include_author_notes=True) for character in selected],
        "timelines": timelines,
        # 两层记忆 (P7): nearest RECENT_FULLTEXT_COUNT finalized chapters as full
        # draft_text, everything older as summary-only (unbounded).
        "recent_fulltext": recent_fulltext,
        "recent_summaries": summaries,
        "style_samples": style_samples,
    }


def build_extractor_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    # §5.L decision: Extractor must NOT see author_notes. It would be tempted
    # to fold "motivation" / "secret" entries into live_fields updates, which
    # would (a) drift author_notes into live_fields and (b) bypass the
    # author's private channel. author_notes is author-owned; only Writer
    # and Expander get to read it for narrative judgement.
    return {
        "chapter": {
            "id": chapter.id,
            "index": chapter.index,
            "title": chapter.title,
            "draft_text": chapter.draft_text,
        },
        "characters": [
            _character_full(character, include_author_notes=False)
            for character in _book_characters(db, book.id)
        ],
    }


def _book_characters(db: Session, book_id: str) -> list[Character]:
    return list(db.scalars(select(Character).where(Character.book_id == book_id).order_by(Character.created_at)).all())


def _recent_finalized(
    db: Session,
    book_id: str,
    before_index: int,
    *,
    fulltext_limit: int,
    style_samples_limit: int,
    chars_per_side: int = STYLE_SAMPLES_CHARS_PER_SIDE,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """One SQL fetch for ``recent_fulltext``, ``recent_summaries``, AND
    ``style_samples``.

    v1.3.1 (KK) P7 — two-tier memory. Originally (§5.L + integration-audit
    item J) this merged ``recent_summaries`` + ``style_samples`` into one
    query; P7 folds the fulltext window in too since all three share the same
    WHERE clause (``book_id`` / ``index < before_index`` / ``status =
    'finalized'``), just ordered by ``index DESC``.

    Semantics:
    - ``recent_fulltext``: the nearest ``fulltext_limit`` finalized chapters,
      each carrying FULL ``draft_text`` — this is the bounded 原文 channel
      (locked invariant: always ≤ ``fulltext_limit``, never grows with total
      chapter count).
    - ``recent_summaries``: every OTHER finalized chapter older than the
      fulltext window, summary-only, with NO upper bound (may grow linearly
      with total chapter count — accepted up to ~300 chapters, see
      ``RECENT_FULLTEXT_COUNT``'s docstring).
    - ``style_samples``: unchanged bounded head/tail snippet mechanism,
      independent of the two above (callers zero it out when the fulltext
      window already hit — see ``build_writer_context``).

    All three return in ascending order (oldest first) so callers don't need
    to ``reversed(...)``. Short-chapter style-samples rule preserved: when
    ``len(draft_text) <= 2 * chars_per_side``, head holds the full text and
    tail collapses to ``''``.
    """
    style_fetch_limit = max(fulltext_limit, style_samples_limit)
    if style_fetch_limit <= 0:
        return [], [], []

    # Two separate result sets are needed: the fulltext/style window is
    # capped at ``style_fetch_limit`` rows, but ``recent_summaries`` must see
    # EVERY older finalized chapter (no upper bound) — a single ``LIMIT``
    # can't serve both. Fetch the bounded window first, then a second query
    # for "everything older than that window" (summaries only, no LIMIT).
    windowed_rows = db.scalars(
        select(Chapter)
        .where(
            Chapter.book_id == book_id,
            Chapter.index < before_index,
            Chapter.status == "finalized",
        )
        .order_by(Chapter.index.desc())
        .limit(style_fetch_limit)
    ).all()

    fulltext_rows = [chapter for chapter in windowed_rows if (chapter.draft_text or "")][:fulltext_limit]
    style_rows = [chapter for chapter in windowed_rows if (chapter.draft_text or "")][:style_samples_limit]

    recent_fulltext = [
        {"index": chapter.index, "draft_text": chapter.draft_text}
        for chapter in reversed(fulltext_rows)
    ]

    style_samples: list[dict[str, Any]] = []
    for chapter in reversed(style_rows):
        text = chapter.draft_text or ""
        if not text:
            continue
        if len(text) <= 2 * chars_per_side:
            head = text
            tail = ""
        else:
            head = text[:chars_per_side]
            tail = text[-chars_per_side:]
        style_samples.append({"chapter_index": chapter.index, "head": head, "tail": tail})

    # Summaries: every finalized chapter OLDER than the fulltext window (no
    # upper bound). ``windowed_rows`` (ordered desc, capped at
    # ``style_fetch_limit`` >= ``fulltext_limit``) already tells us the
    # oldest index still inside the window — anything with a smaller index
    # is "older than the window" and gets a fresh, unbounded query.
    if fulltext_rows:
        oldest_windowed_index = windowed_rows[-1].index
        cutoff_index = min(oldest_windowed_index, before_index)
    else:
        cutoff_index = before_index
    summary_rows = db.scalars(
        select(Chapter)
        .where(
            Chapter.book_id == book_id,
            Chapter.index < cutoff_index,
            Chapter.status == "finalized",
            Chapter.summary.isnot(None),
        )
        .order_by(Chapter.index.desc())
    ).all()
    summaries = [
        {"index": chapter.index, "summary": chapter.summary}
        for chapter in reversed(summary_rows)
    ]

    return recent_fulltext, summaries, style_samples


def _character_timeline(db: Session, book_id: str, character_id: str, *, limit: int) -> list[dict[str, Any]]:
    rows = (
        db.execute(
            select(TimelineEvent, Chapter.index.label("chapter_index"))
            .join(Chapter, TimelineEvent.chapter_id == Chapter.id)
            .where(TimelineEvent.book_id == book_id, TimelineEvent.character_id == character_id)
            .order_by(TimelineEvent.created_at.desc())
            .limit(limit)
        )
        .all()
    )
    rows = list(reversed(rows))
    return [
        {
            "chapter_id": event.chapter_id,
            "chapter_index": chapter_index,
            "event_type": event.event_type,
            "event_text": event.event_text,
            "created_at": event.created_at,
        }
        for event, chapter_index in rows
    ]


def _character_brief(character: Character) -> dict[str, Any]:
    """Expander-facing minimal character payload.

    Keeps the v0.6 ``profile`` one-liner (so the Expander can write tight
    structured prompts without ingesting every field), and adds the full
    ``frozen_fields`` + ``author_notes`` so §5.L.4 focus_traits inference
    has the underlying trait pool to pick from. ``live_fields`` stays out
    — it's Extractor-managed state ("what's true right now"), not a trait
    pool the Expander should reason about.
    """
    frozen = character.frozen_fields or {}
    # v0.7.1 — dropped ``voice`` from the fallback chain. The field was removed
    # from the recommended frozen scalars; we keep ``core_traits`` → ``background``
    # → ``appearance`` so legacy rows without core_traits still get a sensible
    # one-liner without resurrecting the deleted key.
    one_line = (
        frozen.get("core_traits")
        or frozen.get("background")
        or frozen.get("appearance")
        or ""
    )
    return {
        "id": character.id,
        "name": character.name,
        "role": character.role,
        "profile": one_line,
        "frozen_fields": frozen,
        "author_notes": character.author_notes or {},
    }


def _character_full(character: Character, *, include_author_notes: bool) -> dict[str, Any]:
    """Full character payload.

    ``include_author_notes`` gates the §5.L private-channel field:
    - True for Writer / Expander — they need backstage understanding.
    - False for Extractor — see ``build_extractor_context`` for the
      rationale (don't let Extractor leak author_notes into live_fields).
    """
    payload: dict[str, Any] = {
        "id": character.id,
        "name": character.name,
        "role": character.role,
        "frozen_fields": character.frozen_fields or {},
        "live_fields": character.live_fields or {},
    }
    if include_author_notes:
        payload["author_notes"] = character.author_notes or {}
    return payload
