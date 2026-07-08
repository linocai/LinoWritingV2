from __future__ import annotations

from collections.abc import Iterator
from threading import Event
from typing import Any

from app.llm.base import LLMClient, StreamChunk
from app.services.personas import DEFAULT_PERSONAS, compose_system

# v1.0.0 EE Phase 2 (archive/v1.0.0_plan.md §4.2 / §4.4) — the runtime system
# prompt is composed from two layers:
#   1. the *persona* (voice + boundary), DB-stored & App-editable, resolved by
#      ``get_persona(db, 'writer')`` at the router and passed into the
#      constructor — when absent it falls back to ``DEFAULT_PERSONAS['writer']``;
#   2. ``OPERATIONAL_RULES`` below — the fixed §5.L mechanics (card-usage rules,
#      author_notes guardrail, plot-anchor/style/output format). These are
#      agent *behaviour*, not persona, so they stay in code.
# The two are joined as ``persona + "\n\n" + OPERATIONAL_RULES`` (see
# ``compose_system``). The class attribute ``system_prompt`` keeps exposing the
# default-composed prompt for keyword-regression tests.

# v1.3.4 快修 (作者实测报障) — narrative_pov 的中文化标签，用于「本章写作任务」
# 节的「视角」行。未知/缺失值时保持原样或直接省略该半句（见 _render_task_block）。
_NARRATIVE_POV_LABELS: dict[str, str] = {
    "first_person": "第一人称",
    "third_person_limited": "第三人称限知",
    "third_person_omniscient": "第三人称全知",
}


class WriterAgent:
    # v1.4.0 (MM) P1 — 优化师降职: v1.3.4 治好了素材污染，但作者审出了更深的
    # **权威倒置**——Expander 的 200-300 字 ``chapter_directive`` 在质感/
    # 笔触层二次创作，Writer 把它当最高指令而作者的 ``chapter.user_prompt``
    # 原文反而缺席，违背"只文学化作者输入"的红线。``chapter_directive`` 整条
    # 链路（schema 字段 + Expander 产出 + 这里的读取/渲染规则）全部删除。
    # 作者的本章剧情叙述（``user_prompt``，本章节 Bible）现在直接是「本章
    # 写作任务」节的主体、全流程最高权威——见 ``_render_task_block``。
    #
    # v1.5.0 (NN) P1 — 优化师终极精简: Expander 剩下的结构化字段大多仍是
    # "验收清单"式的二次约束，继续把 Writer 从"据作者 Bible 发挥"拽回"逐条
    # 打勾"。四个字段 chapter_goal/must_not_happen/focus_traits/extra_notes
    # 全部删除（无补偿性规则）；``must_happen``→``plot_anchors``，定性从
    # "验收清单"变"领读注解"；新增 chapter_style（≤50 字本章文风，见
    # ``_render_user_message`` 的「# 本章文风」节），取代退场的全局
    # style_directive 频道——全书文风底色现在写在 Writer 人格本身里
    # （``DEFAULT_WRITER_PERSONA``）。
    #
    # v1.3.4 快修 (作者实测报障): 线上实测一次 Writer 输入 12.5k 字里 10.4k 字
    # (83%) 是最近三章的原文 (recent_fulltext) —— 模型把这坨原文当"待续写的
    # 素材"，续出一章跟本章任务毫不相关的 11236 字。根因是 Writer 的输入形态
    # 本身：一坨 JSON 里混着大段原文，模型分不清"这是要素材续写"还是"这是
    # 参考资料"。修法双管齐下：① Writer 彻底断原文，只读梗概（见
    # ``context_pack.build_writer_context``，不再有 recent_fulltext /
    # style_samples）；② user 消息从一坨 JSON 改写成分节的中文文档（见
    # ``_render_user_message`` 及以下小节），让"这是背景资料，不是待续写素材"
    # 这件事从输入形态上就说清楚，而不是只靠一句规则去纠正模型的直觉。
    OPERATIONAL_RULES = """
你是一个中文小说的写作执行者。

# 本章写作任务（作者本章剧情叙述——本章节 Bible）
user 消息「# 本章写作任务」节最前面是作者亲笔写的本章剧情完整叙述——这是
**本章节 Bible，情节的最高权威**，全流程任何其它输入与它冲突时都以它为准。
请严格根据本章剧情来发挥并写作：发挥空间在文笔与细节（怎么铺陈、用什么
节奏和场景把它写活），情节骨架（发生了什么、按什么顺序发生）不能越出这段
叙述划定的范围。跟在 Bible 后面的结构要点（场景/视角/情节锚点）是对 Bible
的整理辅助，帮你确认没漏掉关键点——它们**不是另一份独立指令**，任何结构
要点与 Bible 本身冲突时，以 Bible 为准。结构要点为空时，就完全按 Bible
原文发挥，不要因为缺少结构要点而停笔或等待更多指令。

# 世界观（世界观设定）
「# 世界观设定」节是这本书的世界观设定全文，是**硬约束**：能力体系、地理、
历史、组织、规则性设定一律以它为准——正文不得违背，也不得擅自扩写它没有的
新设定。设定没讲清的地方宁可绕开，不要编造。本章任何写法与世界观设定冲突时，
以世界观设定为准调整写法；它的优先级高于你的临场发挥。

# 角色卡使用规则（读懂这条比读对人设更重要）

「在场角色」节里每个角色的「固定设定」「动态状态」「作者笔记」是**幕后参考**
——用来帮你判断角色在情境中如何行动/说话/选择，**不是清单也不是检查表**。

绝不要为了"证明你看了角色卡"而把人格直接说出来：
- ❌ 反例："林夕谨慎地观察了四周" / "刀子嘴豆腐心的他叹了口气"
- ✓ 正例："林夕在原地站了三息，目光从左到右扫过。" /
        "他骂了一句脏话，声音很轻。然后把自己的水袋递了过去。"

同一项 trait 在整章里**最多用一次**作为行动驱动，不要反复 narrate。
不要把字段名（如 "core_traits"、"background"）或字段内容**逐字搬到正文**。
角色卡是水库，不是必须排空的水桶 — 不自然的 trait 就完全不用。

# 作者笔记处理
「作者笔记」是角色的"演员小抄"：动机/过往/秘密。这是**纯幕后**，
正文里**绝不可有任何句子直接转述作者笔记的内容**。它的作用
只是让你判断角色在抉择关口会怎么走 — 决定后，只写抉择和行动。

# 情节与领读注解
「本章写作任务」节的「情节锚点」是帮你读懂本章 Bible 的领读注解——这些是
本章骨架里不能漏写的节点，不是逐条打勾的验收清单，围绕它们自然铺陈即可，
不必逐字对应，也不必凑数硬塞。
利用「在场角色」节的「近期时间线」保持角色连续性，尤其是角色知道什么、
不知道什么、目标和状态。风格遵循「# 本章文风」节；若该节为空，遵循人格里
的整体文风底色。

# 前情大事记 / 上一章梗概
「# 前情大事记」是上一章之前所有章节的一句话大事记（每章一行）——它是
"不写错的最低事实集"：只是提醒"以前发生过这件事"，不是可展开的细节来源，
不要因为它简短就编造它没写的细节。
「# 上一章梗概」是衔接点：本章要从这个落点接续。
两者都只用于承接与核对，**不要展开、逐字复述或续写其中内容**。

# 字数纪律（目标字数）
目标字数是**交稿要求，不是建议**：若为空或未提供，默认 2500–3500 字；
若提供了具体值，以该值上下浮动 20% 为硬性区间。
动笔前按目标字数分配全章节奏（铺垫/推进/收束），写到目标的八成时开始收束，
落在区间内即完稿——不要因为"写得尽兴"而超出上限。
user 消息末尾的「# 交稿要求」段落给出了本章的具体数字，以它为准。

只输出正文纯文本，不要标题、解释、Markdown 或 JSON。
""".strip()

    # Backward-compat / regression surface: the default-composed system prompt.
    system_prompt = compose_system(DEFAULT_PERSONAS["writer"], OPERATIONAL_RULES)

    def __init__(self, llm: LLMClient, persona: str | None = None) -> None:
        self.llm = llm
        # Persona resolved from DB at the router (``get_persona``); fall back to
        # the code-level default so bare ``WriterAgent(llm)`` callers (tests,
        # internal use) never run with an empty persona.
        self.system_prompt = compose_system(
            persona if persona is not None else DEFAULT_PERSONAS["writer"],
            self.OPERATIONAL_RULES,
        )

    def stream(
        self,
        context: dict[str, Any],
        cancel_event: Event | None = None,
    ) -> Iterator[StreamChunk]:
        # v1.2.0 (HH) P7: pure pass-through — `complete_stream` now yields
        # typed StreamChunk (token/thinking) instead of bare str; this
        # method transparently forwards whatever the LLM client yields.
        yield from self.llm.complete_stream(
            system=self.system_prompt,
            user=self._render_user_message(context),
            temperature=0.7,
            timeout=180,
            cancel_event=cancel_event,
        )

    @staticmethod
    def _render_user_message(context: dict[str, Any]) -> str:
        """Render the Writer's user message as a sectioned Chinese document.

        v1.3.4 快修 (作者实测报障): this used to be a JSON dump of the whole
        context (plus an optional trailing "# 参考前文文风" block). Line 上
        实测该 JSON 里最近三章原文 (recent_fulltext) 占了 83% 的输入，模型把
        它当成了"待续写的素材"而不是背景参考，续出的内容与本章任务完全脱节。
        Two changes together fix this: (a) ``build_writer_context`` no longer
        includes any raw prior-chapter prose at all (no ``recent_fulltext`` /
        ``style_samples`` keys — see context_pack.py); (b) the user message
        itself is now a fixed sequence of named Chinese sections instead of a
        JSON blob, so "这是背景资料" / "这是本章任务" reads as structure, not
        just a rule the model has to remember to apply.

        v1.5.0 (NN) P1 — 定案 #3/#4: the second section swaps source from the
        (now retired) global ``style_directive`` context key to
        ``structured_prompt.chapter_style`` (the Expander's per-chapter ≤50 字
        style note); header renamed「# 文风要求」→「# 本章文风」. The section
        POSITION in the fixed order is unchanged.

        Section order (per PROJECT_PLAN v1.3.4 §改动二, fixed, header renamed
        by v1.5.0 NN P1): 世界观设定 → 本章文风 → 前情大事记 →
        上一章梗概 → 在场角色 → 本章写作任务 (second-to-last) → 交稿要求
        (always last). A section (including its header) is omitted entirely
        when it would otherwise be empty; individual fields within a section
        are omitted line-by-line.
        """
        sections: list[str] = []

        world_setting = (context.get("world_setting") or "").strip()
        if world_setting:
            sections.append(f"# 世界观设定（硬约束，正文不得违背）\n{world_setting}")

        chapter_style = ((context.get("structured_prompt") or {}).get("chapter_style") or "").strip()
        if chapter_style:
            sections.append(f"# 本章文风\n{chapter_style}")

        # v1.5.1 快修 — 梗概中层退场：原「# 前情梗概」节（200 字/章 ×
        # RECENT_SUMMARY_COUNT）删除；上一章之前的所有章一律以一行大事记出现。
        headline_lines = [
            f"第 {item.get('index')} 章：{item.get('headline')}"
            for item in (context.get("recent_headlines") or [])
            if isinstance(item, dict) and (item.get("headline") or "").strip()
        ]
        if headline_lines:
            sections.append(
                "# 前情大事记（每章一行，不写错的最低事实集——不要展开或续写）\n"
                + "\n".join(headline_lines)
            )

        previous = context.get("previous_chapter_summary")
        if isinstance(previous, dict) and (previous.get("summary") or "").strip():
            sections.append(
                "# 上一章梗概（衔接点：本章从这个落点接续）\n"
                f"第 {previous.get('index')} 章：{previous.get('summary')}"
            )

        characters_block = _render_characters_block(context)
        if characters_block:
            sections.append(f"# 在场角色（幕后参考，用于判断言行，不是清单）\n{characters_block}")

        task_block = _render_task_block(context)
        if task_block:
            sections.append(f"# 本章写作任务\n{task_block}")

        # Always last — never empty (falls back to the default 2500-3500 range).
        sections.append(_render_word_count_block(context))

        return "\n\n".join(sections)


def _render_characters_block(context: dict[str, Any]) -> str:
    """Render the "在场角色" section body (everything after the header).

    Each character gets a ``## 姓名（角色）`` sub-header, then one labelled
    bullet-list per non-empty field (固定设定/动态状态/作者笔记/近期时间线).
    Returns ``""`` (section omitted entirely) when there are no involved
    characters at all.
    """
    characters = context.get("characters") or []
    if not characters:
        return ""
    timelines = context.get("timelines") or {}

    blocks: list[str] = []
    for character in characters:
        name = character.get("name") or ""
        role = character.get("role") or ""
        lines = [f"## {name}（{role}）" if role else f"## {name}"]

        frozen = character.get("frozen_fields") or {}
        if frozen:
            lines.append("固定设定：")
            lines.extend(f"- {key}：{value}" for key, value in frozen.items())

        live = character.get("live_fields") or {}
        if live:
            lines.append("动态状态：")
            lines.extend(f"- {key}：{value}" for key, value in live.items())

        notes = character.get("author_notes") or {}
        if notes:
            lines.append("作者笔记（纯幕后，绝不入正文）：")
            lines.extend(f"- {key}：{value}" for key, value in notes.items())

        events = timelines.get(character.get("id")) or []
        if events:
            lines.append("近期时间线：")
            lines.extend(
                f"- 第{event.get('chapter_index')}章：{event.get('event_text')}" for event in events
            )

        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _render_task_block(context: dict[str, Any]) -> str:
    """Render the "本章写作任务" section body (everything after the header).

    v1.4.0 (MM) P1 — 优化师降职: the PRIMARY content is now the author's own
    ``user_prompt`` (top-level context key, lifted by
    ``context_pack.build_writer_context`` from ``chapter.user_prompt``) — 本章
    节 Bible, the highest authority in the whole pipeline. The
    ``chapter_directive`` line is GONE entirely (schema field deleted — no
    more Expander-authored steering standing in front of the author's own
    words). The ``structured_prompt`` blueprint fields that follow are
    rendered as supporting structure notes, never a replacement for the
    Bible. ``continuity_alerts`` — the Expander's ONE remaining
    steering-adjacent output — is intentionally NEVER read here (or anywhere
    in this module): it's a note FOR THE AUTHOR, not a Writer input (P1
    decision #1).

    v1.5.0 (NN) P1 — 优化师终极精简: ``chapter_goal`` / ``must_not_happen`` /
    ``focus_traits`` / ``extra_notes`` are GONE (schema fields deleted — never
    read here even when an old chapter's persisted JSON still carries one of
    these dead keys via ``extra="allow"``). ``must_happen`` → ``plot_anchors``
    (renamed): label follows suit, "必须发生" → "情节锚点", matching the new
    领读注解 (guided-reading annotation) framing — see
    ``PromptExpanderAgent.OPERATIONAL_RULES``. ``chapter_style`` is rendered
    as its own top-level「# 本章文风」section (see ``_render_user_message``),
    not here. Returns ``""`` (section omitted entirely) when the Bible and
    every blueprint field are all empty.
    """
    structured_prompt = context.get("structured_prompt") or {}
    lines: list[str] = []

    user_prompt = (context.get("user_prompt") or "").strip()
    if user_prompt:
        lines.append(
            "作者本章剧情叙述——本章节 Bible，情节的最高权威，"
            "任何结构要点与它冲突时以它为准：\n" + user_prompt
        )

    scene = structured_prompt.get("scene_setting")
    pov_raw = structured_prompt.get("narrative_pov")
    pov_label = _NARRATIVE_POV_LABELS.get(pov_raw, pov_raw if isinstance(pov_raw, str) and pov_raw.strip() else None)
    scene_parts = []
    if isinstance(scene, str) and scene.strip():
        scene_parts.append(f"场景：{scene.strip()}")
    if pov_label:
        scene_parts.append(f"视角：{pov_label}")
    if scene_parts:
        lines.append("／".join(scene_parts))

    plot_anchors = [item.strip() for item in (structured_prompt.get("plot_anchors") or []) if isinstance(item, str) and item.strip()]
    if plot_anchors:
        lines.append("情节锚点：")
        lines.extend(f"- {item}" for item in plot_anchors)

    return "\n".join(lines)


def _render_word_count_block(context: dict[str, Any]) -> str:
    """Render the trailing ``# 交稿要求`` word-count block.

    Reads ``target_word_count`` from the top-level context key (lifted by
    ``build_writer_context``) with a fallback to ``structured_prompt`` so bare
    contexts (tests, internal callers) behave identically. Non-positive or
    non-numeric values degrade to the default range rather than raising.
    """
    raw = context.get("target_word_count")
    if raw is None:
        raw = (context.get("structured_prompt") or {}).get("target_word_count")
    target: int | None = None
    if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw > 0:
        target = int(raw)
    if target is None:
        requirement = "本章目标字数 2500–3500 字，完稿须落在该区间内。"
    else:
        low, high = int(target * 0.8), int(target * 1.2)
        requirement = f"本章目标字数 {target} 字，完稿须落在 {low}–{high} 字内。"
    return f"# 交稿要求\n{requirement}写到目标的八成时开始收束，抵达区间即完稿。"
