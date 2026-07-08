from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent

# Style-sample knobs — originally for WriterAgent's "参考前文文风" block.
#
# v1.3.4 快修 (作者实测报障): that block is now GONE — line 上实测 Writer 输入
# 83% 被前三章原文占据 (recent_fulltext), 模型把任务当素材续写导致大段跑偏。
# Writer 彻底断原文: ``build_writer_context`` no longer surfaces
# ``recent_fulltext`` OR ``style_samples`` at all (both keys deleted from its
# return dict — see below). These two constants now serve only as the
# ``_recent_finalized`` call-site's bypass value (a non-zero
# ``style_samples_limit`` keeps that function's ``style_fetch_limit <= 0``
# early-return from firing, which would otherwise also wipe out
# ``recent_summaries``/``recent_headlines``) — the ``style_samples`` list it
# computes is discarded, never returned to the Writer. The mechanism itself
# (``_recent_finalized``'s head/tail slicing) is untouched and still directly
# unit-tested (test_style_samples.py) at the function level.
STYLE_SAMPLES_CHAPTER_COUNT = 2
STYLE_SAMPLES_CHARS_PER_SIDE = 400

# v1.3.2 (LL) P3 — three-tier memory (the third tier built here; supersedes
# the v1.3.1 KK P7 two-tier comment below). The most recent
# ``RECENT_FULLTEXT_COUNT`` finalized chapters are fed to Expander/Writer as
# FULL ``draft_text`` (原文); the next ``RECENT_SUMMARY_COUNT`` older finalized
# chapters are fed as full ``summary`` (~200 字/章); anything OLDER than both
# windows is mechanically distilled down to a ``headline`` (一句话大事记, ≤
# ``HEADLINE_MAX_CHARS`` chars — see ``_distill_headline``). New invariant
# (locked, see test_phase5_end_to_end.py INV-1''): the fulltext channel stays
# bounded at exactly ``RECENT_FULLTEXT_COUNT``, the full-summary channel stays
# bounded at exactly ``RECENT_SUMMARY_COUNT``, and only ``recent_headlines``
# (~30 字/章) grows linearly with total chapter count — token budget: 3×~3000
# (fulltext) + 30×~200 (summary) + (N-33)×~30 (headline), acceptable up to
# ~2000 chapters (linear growth slowed ~6-7x vs the old unbounded-summary
# design; see PROJECT_PLAN §4 P3 / Backlog §3.1 for true-bounded memory at
# super-long-form scale, not built here).
#
# v1.3.4 快修: still governs the Expander's ``recent_fulltext`` window
# unchanged. The Writer no longer reads this tier at all (see
# ``build_writer_context``) — its summary window now starts from the
# immediately-preceding chapter instead of being carved out by this constant.
RECENT_FULLTEXT_COUNT = 3

# v1.3.2 (LL) P3 — the middle tier: finalized chapters older than the
# fulltext window but within this many chapters still get their FULL summary
# (replaces the old "unbounded summaries" behaviour from KK P7). Author-locked
# at 30 (PROJECT_PLAN §4 已决议 #3 — "not moved").
RECENT_SUMMARY_COUNT = 30

# v1.3.2 (LL) P3 — max chars of a mechanically-distilled ``headline`` (before
# any trailing "…" is appended). See ``_distill_headline`` for the exact
# pseudocode (locked verbatim by PROJECT_PLAN §4 P3).
HEADLINE_MAX_CHARS = 40

# Terminator characters used to find the "first sentence" of a summary when
# distilling a headline. "；" (semicolon) is deliberately included — cutting
# an early clause short there is intentional (a long first clause beats no
# boundary at all).
_HEADLINE_TERMINATORS = "。！？；\n"


def _distill_headline(summary: str | None) -> str | None:
    """Mechanically distill a chapter ``summary`` into a one-line 一句话大事记
    for the third memory tier (``recent_headlines``).

    v1.3.2 (LL) P3 pseudocode, locked verbatim by PROJECT_PLAN §4 P3 / 已决议 #2:
    - ``headline`` = the prefix of ``summary`` UP TO AND INCLUDING the first
      terminator character among ``_HEADLINE_TERMINATORS`` (。！？；\\n).
    - If there is no terminator anywhere in ``summary``, OR that first-sentence
      prefix is longer than ``HEADLINE_MAX_CHARS``, fall back to the first
      ``HEADLINE_MAX_CHARS`` characters of ``summary`` + "…".
    - Empty string / ``None`` summary → skip (returns ``None``, same as "no
      summary at all") — never invents a headline out of nothing.

    This is PURE mechanical distillation of the Extractor's own summary —
    never a fresh LLM call, never new content. Preserves the red line
    ("不发明情节"): a headline is always, after stripping any trailing "…", a
    literal prefix substring of the summary it was distilled from.
    """
    if not summary:
        return None
    first_terminator_index = next(
        (i for i, ch in enumerate(summary) if ch in _HEADLINE_TERMINATORS), None
    )
    if first_terminator_index is not None and first_terminator_index + 1 <= HEADLINE_MAX_CHARS:
        return summary[: first_terminator_index + 1]
    return summary[:HEADLINE_MAX_CHARS] + "…"


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
    # v1.3.2 (LL) P3 — three-tier memory: the nearest ``RECENT_FULLTEXT_COUNT``
    # finalized chapters are read as full ``draft_text`` (``recent_fulltext``);
    # the next ``RECENT_SUMMARY_COUNT`` older chapters are full ``summary``
    # (``recent_summaries``); anything older still is a one-line
    # ``headline`` (``recent_headlines``). The Expander's continuity check
    # now grounds itself in all three.
    recent_fulltext, summaries, headlines, _ = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=RECENT_FULLTEXT_COUNT,
        style_samples_limit=0,
        summary_limit=RECENT_SUMMARY_COUNT,
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
        # 三层记忆 (P3): nearest RECENT_FULLTEXT_COUNT finalized chapters as full
        # draft_text, next RECENT_SUMMARY_COUNT as full summary, everything
        # older still as a one-line headline (recent_headlines).
        "recent_fulltext": recent_fulltext,
        "recent_summaries": summaries,
        "recent_headlines": headlines,
        "all_characters": [_character_brief(character) for character in characters],
    }


def build_writer_context(db: Session, book: Book, chapter: Chapter) -> dict[str, Any]:
    # v1.0.0 EE Phase 3 (§4.2) — the Writer reads along TWO distinct lines (P1
    # 红线, "两条线分明"):
    #   · 方向 (direction): ``chapter_directive`` — the Expander's 200-300 字
    #     steering, surfaced as a TOP-LEVEL key (lifted out of structured_prompt)
    #     so it reads as its own input, not buried inside the blueprint JSON.
    #   · 知识 (knowledge): ``characters`` / ``timelines`` / ``recent_summaries``
    #     / ``recent_headlines`` / ``previous_chapter_summary`` — the relevant
    #     cards + memory, delivered by Context Pack on the same separate line
    #     they always were. The directive NEVER carries this knowledge (the
    #     Expander is forbidden from copying cards into it); it only points
    #     the Writer where to go. (v1.3.4 快修: no raw prior-chapter prose is
    #     ever in this line any more — see the ``_recent_finalized`` call
    #     below.)
    # The directive degrades gracefully: old / un-expanded chapters have no
    # ``chapter_directive`` in their structured_prompt → ``None`` here, and the
    # Writer simply falls back to the structured_prompt blueprint (the pre-P3
    # behaviour). Never raises.
    structured_prompt = chapter.structured_prompt or {}
    involved_ids = structured_prompt.get("characters_involved") or []
    characters = _book_characters(db, book.id)
    selected = [character for character in characters if character.id in involved_ids]
    timelines = {character.id: _character_timeline(db, book.id, character.id, limit=15) for character in selected}

    # v1.3.4 快修 (作者实测报障): Writer 彻底断原文. 线上实测一次 12.5k 字的
    # Writer 输入里 10.4k 字 (83%) 是 recent_fulltext (前三章原文) ——模型把
    # 这坨原文当"待续写的素材"，续出一章跟任务毫不相关的 11236 字。
    # 修法：Writer 不再读 recent_fulltext / style_samples 里的任何前文原文，
    # 只读梗概。``fulltext_limit=0`` 让 recent_fulltext 恒为空；
    # ``style_samples_limit`` 仍传 STYLE_SAMPLES_CHAPTER_COUNT（而非 0）只是
    # 为了绕开 ``_recent_finalized`` 的 ``style_fetch_limit <= 0`` 提前返回
    # （那个分支会把 summaries/headlines 也一并清空）——下面把它算出来的
    # style_samples 直接丢弃，从不放进返回的 context。
    # 副作用（预期内、合意）：fulltext_limit=0 时 ``_recent_finalized`` 内部
    # 恒无 fulltext_rows，于是它退化为"该章之前的全部 finalized 章节都参与
    # summary/headline 切分"——summary 窗口从"上一章"起算，不再被 fulltext
    # 窗口切走最近 3 章（这些章节仍然只是 summary-only，从未获得 raw
    # draft_text）。``_recent_finalized`` 函数本身不改；expander 侧
    # (``build_expander_context``) 的三层记忆调用照旧不变。
    _, summaries, headlines, _ = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=0,
        style_samples_limit=STYLE_SAMPLES_CHAPTER_COUNT,
        summary_limit=RECENT_SUMMARY_COUNT,
    )
    # 上一章梗概单列为衔接点 (previous_chapter_summary) —— summaries 按升序
    # (最旧在前) 返回，故最后一项 = 离当前章最近的一章。recent_summaries 扣除
    # 它，从第 2 近的章起，凑满 RECENT_SUMMARY_COUNT 总窗口，不重复计数。
    if summaries:
        previous_chapter_summary: dict[str, Any] | None = summaries[-1]
        recent_summaries = summaries[:-1]
    else:
        previous_chapter_summary = None
        recent_summaries = []
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
        # v1.3.3 快修 — 字数服从性: lifted out of structured_prompt as its own
        # top-level key (same pattern as chapter_directive) so the Writer's
        # trailing「# 交稿要求」block and the model's attention both read it
        # without digging through the blueprint JSON.
        "target_word_count": structured_prompt.get("target_word_count"),
        "structured_prompt": structured_prompt,
        # 知识 (knowledge) — Writer reads author_notes for backstage
        # understanding (§5.L.5); the system_prompt forbids narrating it
        # directly, so feeding it is safe and lets the model judge "what
        # would this character do here".
        "characters": [_character_full(character, include_author_notes=True) for character in selected],
        "timelines": timelines,
        # v1.3.4 快修 — 衔接点单列: the immediately-preceding finalized
        # chapter's summary, pulled out of the summary tier so the Writer
        # sees exactly where "本章从这里接续" without hunting through the
        # rest of recent_summaries. ``None`` when this is the book's first
        # chapter (no prior finalized chapter exists yet).
        "previous_chapter_summary": previous_chapter_summary,
        "recent_summaries": recent_summaries,
        "recent_headlines": headlines,
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
    summary_limit: int,
    chars_per_side: int = STYLE_SAMPLES_CHARS_PER_SIDE,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """One SQL fetch for ``recent_fulltext``, ``recent_summaries``,
    ``recent_headlines``, AND ``style_samples``.

    v1.3.2 (LL) P3 — three-tier memory. Originally (§5.L + integration-audit
    item J) this merged ``recent_summaries`` + ``style_samples`` into one
    query; v1.3.1 (KK) P7 folded the fulltext window in too. P3 adds the
    third tier: chapters older than BOTH the fulltext window and the
    full-summary window are mechanically distilled into ``recent_headlines``
    instead of dropped or fed unbounded.

    ``summary_limit`` is a REQUIRED keyword (no default bound to the module
    constant) so callers always resolve ``RECENT_SUMMARY_COUNT`` at CALL time
    — this matters because tests monkeypatch the module attribute to a small
    value to make the headline tier reachable without seeding 30+ chapters; a
    default argument would capture the value at *function-definition* time
    and silently ignore the monkeypatch (the same reason ``fulltext_limit``
    /``style_samples_limit`` have never had defaults here).

    Semantics:
    - ``recent_fulltext``: the nearest ``fulltext_limit`` finalized chapters,
      each carrying FULL ``draft_text`` — the bounded 原文 channel (locked
      invariant: always ≤ ``fulltext_limit``, never grows with total chapter
      count).
    - ``recent_summaries``: the next ``summary_limit`` finalized chapters
      older than the fulltext window, each carrying FULL ``summary`` — also
      bounded now (locked invariant: always ≤ ``summary_limit``; was
      unbounded pre-P3).
    - ``recent_headlines``: every OTHER finalized chapter older than BOTH
      windows, each carrying only a mechanically-distilled ``headline`` (see
      ``_distill_headline``) — unbounded, grows linearly but ~6-7x slower
      than feeding full summaries would.
    - ``style_samples``: unchanged bounded head/tail snippet mechanism,
      independent of the three above (callers zero it out when the fulltext
      window already hit — see ``build_writer_context``).

    All four return in ascending order (oldest first) so callers don't need
    to ``reversed(...)``. Short-chapter style-samples rule preserved: when
    ``len(draft_text) <= 2 * chars_per_side``, head holds the full text and
    tail collapses to ``''``.
    """
    style_fetch_limit = max(fulltext_limit, style_samples_limit)
    if style_fetch_limit <= 0:
        return [], [], [], []

    # Two separate result sets are needed: the fulltext/style window is
    # capped at ``style_fetch_limit`` rows, but the summary + headline tiers
    # must see EVERY older finalized chapter — a single ``LIMIT`` can't serve
    # both. Fetch the bounded window first, then a second query for
    # "everything older than that window" (split in memory into the bounded
    # full-summary tier + the unbounded headline tier).
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

    # Summary + headline tiers: every finalized chapter OLDER than the
    # fulltext window (no LIMIT here — ``windowed_rows`` (ordered desc,
    # capped at ``style_fetch_limit`` >= ``fulltext_limit``) already tells us
    # the oldest index still inside the window; anything with a smaller index
    # is "older than the window" and gets a fresh query).
    if fulltext_rows:
        oldest_windowed_index = windowed_rows[-1].index
        cutoff_index = min(oldest_windowed_index, before_index)
    else:
        cutoff_index = before_index
    older_rows = db.scalars(
        select(Chapter)
        .where(
            Chapter.book_id == book_id,
            Chapter.index < cutoff_index,
            Chapter.status == "finalized",
            Chapter.summary.isnot(None),
        )
        .order_by(Chapter.index.desc())
    ).all()

    # ``older_rows`` is ordered desc (nearest-first) — the first
    # ``summary_limit`` rows are the nearest, so they get the FULL summary;
    # anything past that is mechanically distilled into a headline instead.
    summary_rows = older_rows[:summary_limit]
    headline_rows = older_rows[summary_limit:]

    summaries = [
        {"index": chapter.index, "summary": chapter.summary}
        for chapter in reversed(summary_rows)
    ]

    recent_headlines: list[dict[str, Any]] = []
    for chapter in reversed(headline_rows):
        headline = _distill_headline(chapter.summary)
        if headline is None:
            continue
        recent_headlines.append({"index": chapter.index, "headline": headline})

    return recent_fulltext, summaries, recent_headlines, style_samples


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
