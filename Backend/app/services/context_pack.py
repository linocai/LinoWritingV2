from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent

# NB: the ``style_samples`` mechanism (WriterAgent's original "参考前文文风"
# head/tail snippet block) was retired in v1.5.2 (清理收口). It had been dead
# since v1.3.4 (Writer 彻底断原文 — the block was removed from the prompt then,
# but the ``_recent_finalized`` slicing kept being computed and discarded).
# The two ``STYLE_SAMPLES_*`` knobs and the whole head/tail slice are gone;
# ``_recent_finalized`` now only serves the three memory tiers below.

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
    # structure it + check continuity + frame scope" (no more whole-book
    # outline input; v1.4.0 MM P1 dropped the "distill a directive" 4th
    # responsibility entirely — see ``PromptExpanderAgent.OPERATIONAL_RULES``).
    # Assembled just-in-time from:
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
    # the Expander can still pick characters_involved (选角) even on the first
    # pass when the involved set is still empty.
    #
    # v1.3.2 (LL) P3 — three-tier memory: the nearest ``RECENT_FULLTEXT_COUNT``
    # finalized chapters are read as full ``draft_text`` (``recent_fulltext``);
    # the next ``RECENT_SUMMARY_COUNT`` older chapters are full ``summary``
    # (``recent_summaries``); anything older still is a one-line
    # ``headline`` (``recent_headlines``). The Expander's continuity check
    # now grounds itself in all three.
    recent_fulltext, summaries, headlines = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=RECENT_FULLTEXT_COUNT,
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
            # v1.5.0 (NN) P1 定案 #4 — the global ``style_directive`` channel
            # is retired: ``book.style_directive`` is no longer surfaced here
            # at all (the DB column + ``BookRead`` schema field stay, vestigial,
            # zero migration — nothing downstream reads this dict for it any
            # more).
        },
        "chapter": {
            "id": chapter.id,
            "index": chapter.index,
            "title": chapter.title,
            "user_prompt": chapter.user_prompt,
        },
        # v1.5.0 (NN) P1 定案 #1 — ``extra_notes`` is deleted (full chain): the
        # "existing_extra_notes preserved across re-expand" mechanism this key
        # used to feed (see ``PromptExpanderAgent.expand``, pre-v1.5.0) is
        # gone along with the field itself. No replacement key is added here.
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
    # v1.4.0 (MM) P1 — 优化师降职后, the Writer reads along TWO distinct lines,
    # but the 方向 (direction) line is now the AUTHOR'S OWN WORDS instead of an
    # Expander-authored directive:
    #   · 剧情 (plot, highest authority): ``user_prompt`` — ``chapter.user_prompt``
    #     verbatim, surfaced as a TOP-LEVEL key (mirrors how ``chapter_directive``
    #     used to be lifted out, but this is the author's own narrative, never
    #     agent-authored). This is 本章节 Bible — see ``agents.writer`` for how
    #     it's rendered as the「本章写作任务」section's primary content.
    #   · 知识 (knowledge): ``characters`` / ``timelines`` /
    #     ``recent_headlines`` / ``previous_chapter_summary`` — the relevant
    #     cards + memory, delivered by Context Pack on the same separate line
    #     they always were. (v1.3.4 快修: no raw prior-chapter prose is ever in
    #     this line any more — see the ``_recent_finalized`` call below.)
    # ``chapter_directive`` is GONE entirely (schema field deleted, P1)  — no
    # more Expander-authored steering standing in front of the author's own
    # words. Graceful degrade: an empty/blank ``user_prompt`` (should not
    # normally happen — Step 1 requires it — but old/malformed rows are
    # possible) simply omits the「本章写作任务」Bible line; the Writer still
    # runs off the structured_prompt blueprint fields. Never raises.
    structured_prompt = chapter.structured_prompt or {}
    involved_ids = structured_prompt.get("characters_involved") or []
    characters = _book_characters(db, book.id)
    selected = [character for character in characters if character.id in involved_ids]
    timelines = {character.id: _character_timeline(db, book.id, character.id, limit=15) for character in selected}

    # v1.3.4 快修 (作者实测报障): Writer 彻底断原文. 线上实测一次 12.5k 字的
    # Writer 输入里 10.4k 字 (83%) 是 recent_fulltext (前三章原文) ——模型把
    # 这坨原文当"待续写的素材"，续出一章跟任务毫不相关的 11236 字。
    # 修法：Writer 不再读任何前文原文，只读梗概。``fulltext_limit=0`` 让
    # recent_fulltext 恒为空；v1.5.2 起 fulltext_limit=0 直接跳过 windowed
    # 查询，cutoff=before_index，于是"该章之前的全部 finalized 章节都参与
    # summary/headline 切分"——summary 窗口从"上一章"起算。``_recent_finalized``
    # expander 侧 (``build_expander_context``) 的三层记忆调用照旧不变。
    # v1.5.1 快修 (作者拍板) — Writer 的 200 字梗概中层退场：完整梗概只保留
    # **上一章**这一份（衔接点，不可替代——只有它带着"上一章怎么收尾"的落点），
    # 更早的全部章一律降为每章一行的机械大事记（``recent_headlines``，
    # ≤40 字/章）。理由：Writer 需要的不是"前情故事"而是"不写错的最低事实
    # 集"——大事记（全书视角、无角色过滤）+ 时间线（在场角色事件）+ 角色卡
    # （当前状态）三者合起来即覆盖梗概中层的全部功能；砍掉它把记忆区体积从
    # ~200×30 字压到 200 + 40×N 字。``summary_limit=1`` 让 ``_recent_finalized``
    # 只给最近一章完整 summary，其余全部落 headline 切分。expander 侧
    # （校对员，连续性核对需要细节）的三层记忆调用照旧不变——梗概数据本身
    # 照常由档案员产出，只是 Writer 不再吃中层。
    _, summaries, headlines = _recent_finalized(
        db,
        book.id,
        chapter.index,
        fulltext_limit=0,
        summary_limit=1,
    )
    previous_chapter_summary: dict[str, Any] | None = summaries[-1] if summaries else None
    return {
        "world_setting": book.world_setting or "",
        # v1.5.0 (NN) P1 定案 #4 — the global ``style_directive`` channel is
        # retired: no longer surfaced here. Per-chapter style now flows solely
        # via ``structured_prompt.chapter_style`` (see agents/writer.py); the
        # book-wide style baseline lives in the Writer persona itself.
        # 剧情 (plot, highest authority) — v1.4.0 (MM) P1 决议 #2: the
        # author's own chapter narrative, verbatim, its own top-level line.
        # This is 本章节 Bible — see ``agents.writer._render_task_block``.
        "user_prompt": chapter.user_prompt or "",
        # v1.3.3 快修 — 字数服从性: lifted out of structured_prompt as its own
        # top-level key so the Writer's trailing「# 交稿要求」block and the
        # model's attention both read it without digging through the
        # blueprint JSON.
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
        # memory tiers. ``None`` when this is the book's first chapter
        # (no prior finalized chapter exists yet). v1.5.1: the 200-字 summary
        # middle tier is GONE from the Writer — everything older than the
        # previous chapter arrives only as one-line ``recent_headlines``.
        "previous_chapter_summary": previous_chapter_summary,
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
    summary_limit: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """One-or-two SQL fetches for the three memory tiers: ``recent_fulltext``,
    ``recent_summaries``, ``recent_headlines``.

    v1.3.2 (LL) P3 — three-tier memory. Originally (§5.L + integration-audit
    item J) this merged ``recent_summaries`` + the (v1.5.2-retired)
    ``style_samples`` into one query; v1.3.1 (KK) P7 folded the fulltext
    window in too. P3 adds the third tier: chapters older than BOTH the
    fulltext window and the full-summary window are mechanically distilled
    into ``recent_headlines`` instead of dropped or fed unbounded.

    ``summary_limit`` is a REQUIRED keyword (no default bound to the module
    constant) so callers always resolve ``RECENT_SUMMARY_COUNT`` at CALL time
    — this matters because tests monkeypatch the module attribute to a small
    value to make the headline tier reachable without seeding 30+ chapters; a
    default argument would capture the value at *function-definition* time
    and silently ignore the monkeypatch (same for ``fulltext_limit``).

    Semantics:
    - ``recent_fulltext``: the nearest ``fulltext_limit`` finalized chapters,
      each carrying FULL ``draft_text`` — the bounded 原文 channel (locked
      invariant: always ≤ ``fulltext_limit``, never grows with total chapter
      count). ``fulltext_limit == 0`` (the Writer path — 断原文) SKIPS the
      windowed query entirely: ``recent_fulltext`` is empty and the cutoff for
      the summary/headline tiers is ``before_index`` (every finalized chapter
      older than the current one participates in summary/headline splitting).
    - ``recent_summaries``: the next ``summary_limit`` finalized chapters
      older than the fulltext window, each carrying FULL ``summary`` — also
      bounded (locked invariant: always ≤ ``summary_limit``; was unbounded
      pre-P3).
    - ``recent_headlines``: every OTHER finalized chapter older than BOTH
      windows, each carrying only a mechanically-distilled ``headline`` (see
      ``_distill_headline``) — unbounded, grows linearly but ~6-7x slower
      than feeding full summaries would.

    All three return in ascending order (oldest first) so callers don't need
    to ``reversed(...)``.
    """
    # Bounded fulltext window (原文): the nearest ``fulltext_limit`` finalized
    # chapters, each carrying FULL ``draft_text``. When ``fulltext_limit == 0``
    # the window query is skipped and the summary/headline cutoff is
    # ``before_index`` (the Writer path).
    if fulltext_limit > 0:
        windowed_rows = db.scalars(
            select(Chapter)
            .where(
                Chapter.book_id == book_id,
                Chapter.index < before_index,
                Chapter.status == "finalized",
            )
            .order_by(Chapter.index.desc())
            .limit(fulltext_limit)
        ).all()
        fulltext_rows = [chapter for chapter in windowed_rows if (chapter.draft_text or "")][:fulltext_limit]
        recent_fulltext = [
            {"index": chapter.index, "draft_text": chapter.draft_text}
            for chapter in reversed(fulltext_rows)
        ]
        # Summary + headline tiers see every finalized chapter OLDER than the
        # fulltext window: ``windowed_rows`` (ordered desc, capped at
        # ``fulltext_limit``) tells us the oldest index still inside the
        # window; anything with a smaller index gets the fresh query below.
        if fulltext_rows:
            oldest_windowed_index = windowed_rows[-1].index
            cutoff_index = min(oldest_windowed_index, before_index)
        else:
            cutoff_index = before_index
    else:
        recent_fulltext = []
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

    return recent_fulltext, summaries, recent_headlines


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
    ``frozen_fields`` + ``author_notes`` so the Expander's 领读 (plot_anchors /
    chapter_style) pass has the underlying character pool to reason from.
    ``live_fields`` stays out — it's Extractor-managed state ("what's true
    right now"), not a trait pool the Expander should reason about.
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
