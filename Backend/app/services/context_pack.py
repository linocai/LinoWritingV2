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
STYLE_SAMPLES_CHAPTER_COUNT = 2
STYLE_SAMPLES_CHARS_PER_SIDE = 400

# v0.7 §5.L — recent-summaries knob lives next to STYLE_SAMPLES_* so the
# merged-query helper below has both inputs in one place.
RECENT_SUMMARIES_COUNT = 2


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
    summaries, _ = _recent_finalized(
        db,
        book.id,
        chapter.index,
        summaries_limit=RECENT_SUMMARIES_COUNT,
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
    # Merged query (§5.L + audit J): summaries + style_samples used to fire
    # two near-identical SELECTs against the chapters table; now they share
    # one query and split in memory.
    summaries, style_samples = _recent_finalized(
        db,
        book.id,
        chapter.index,
        summaries_limit=RECENT_SUMMARIES_COUNT,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        chars_per_side=STYLE_SAMPLES_CHARS_PER_SIDE,
    )
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
    summaries_limit: int,
    style_samples_limit: int,
    chars_per_side: int = STYLE_SAMPLES_CHARS_PER_SIDE,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """One SQL fetch for both ``recent_summaries`` and ``style_samples``.

    Merged from the v0.6 pair ``_recent_summaries`` / ``_style_samples``
    (§5.L + integration-audit item J). Their WHERE clauses overlapped almost
    completely — same ``book_id`` / ``index < before_index`` / ``status =
    'finalized'`` — so we issue one SELECT that orders by ``index DESC`` and
    pulls ``max(summaries_limit, style_samples_limit)`` rows, then split in
    memory.

    Returns ``(summaries, style_samples)`` already in ascending order
    (oldest first) so callers don't need to ``reversed(...)``. Empty inputs
    (limit 0) return an empty list without touching the DB if both limits
    are 0.

    Short-chapter style-samples rule preserved from the old helper: when
    ``len(draft_text) <= 2 * chars_per_side``, head holds the full text and
    tail collapses to ``''``.
    """
    fetch_limit = max(summaries_limit, style_samples_limit)
    if fetch_limit <= 0:
        return [], []

    rows = db.scalars(
        select(Chapter)
        .where(
            Chapter.book_id == book_id,
            Chapter.index < before_index,
            Chapter.status == "finalized",
        )
        .order_by(Chapter.index.desc())
        .limit(fetch_limit)
    ).all()

    # Slice + transform in memory so we don't burn extra round-trips.
    summary_rows = [chapter for chapter in rows if chapter.summary is not None][:summaries_limit]
    style_rows = [chapter for chapter in rows if (chapter.draft_text or "")][:style_samples_limit]

    summaries = [
        {"index": chapter.index, "summary": chapter.summary}
        for chapter in reversed(summary_rows)
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

    return summaries, style_samples


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
