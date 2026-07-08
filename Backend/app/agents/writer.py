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
#      focus_traits handling, author_notes guardrail, plot/style/output format).
#      These are agent *behaviour*, not persona, so they stay in code.
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

# 本章方向（本章写作任务·本章创作指令）
user 消息「# 本章写作任务」节里的「本章创作指令」是优化师给你的「本章创作指令」
(200–300 字)——本章的**方向盘**：本章要达成什么、张力在哪、承接什么落点、
注意哪条还开着的伏笔。**严格按它执行**，不越权推进指令之外的剧情。
它只给方向，**不给知识**——角色是谁、知道什么、当前状态，全在「在场角色」节
里（另一条线，见下）；本章创作指令与角色卡是**分开的两条线**，不要把
创作指令当角色资料。若本章没有「本章创作指令」，就退回按「本章写作任务」节
其余字段写，不要因为缺少创作指令而停笔或编一个方向出来。

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

# 本章重点
「本章写作任务」节的「聚焦特质」是本章**可重点 emerge** 的 0-2 个特质，
其它 trait 保持隐性，不主动展示。**为空时不要刻意 emerge 任何特质** —
按 plot 自然行进即可，不要为了凑满"重点"而编一个出来。

# 作者笔记处理
「作者笔记」是角色的"演员小抄"：动机/过往/秘密。这是**纯幕后**，
正文里**绝不可有任何句子直接转述作者笔记的内容**。它的作用
只是让你判断角色在抉择关口会怎么走 — 决定后，只写抉择和行动。

# 情节与风格约束
必须写到「本章写作任务」节「必须发生」里的事件。
「不可发生」里的事件、元素和信息一字不提。
利用「在场角色」节的「近期时间线」保持角色连续性，尤其是角色知道什么、
不知道什么、目标和状态。风格遵循「# 文风要求」节。

# 前情梗概 / 更早章节大事记 / 上一章梗概
「# 前情梗概」是背景资料，不是写作素材——**不要展开、复述或续写其中内容**，
只用于了解"最近发生过什么"、衔接情节连贯性。
「# 更早章节大事记」是更早所有章节的一句话大事记（每章一行），用于长程
连续性——只是提醒"很久以前发生过这件事"，不是可展开的细节来源，不要因为
它简短就编造它没写的细节。
「# 上一章梗概」是衔接点：本章要从这个落点接续。
三者都只用于承接与核对，**不要逐字复述或续写其中内容**。

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

        Section order (per PROJECT_PLAN v1.3.4 §改动二, fixed): 世界观设定 →
        文风要求 → 前情梗概 → 更早章节大事记 → 上一章梗概 → 在场角色 →
        本章写作任务 (second-to-last) → 交稿要求 (always last). A section
        (including its header) is omitted entirely when it would otherwise be
        empty; individual fields within a section are omitted line-by-line.
        """
        sections: list[str] = []

        world_setting = (context.get("world_setting") or "").strip()
        if world_setting:
            sections.append(f"# 世界观设定（硬约束，正文不得违背）\n{world_setting}")

        style_directive = (context.get("style_directive") or "").strip()
        if style_directive:
            sections.append(f"# 文风要求\n{style_directive}")

        summary_lines = [
            f"第 {item.get('index')} 章：{item.get('summary')}"
            for item in (context.get("recent_summaries") or [])
            if isinstance(item, dict) and (item.get("summary") or "").strip()
        ]
        if summary_lines:
            sections.append(
                "# 前情梗概（背景资料，非写作素材——不要展开、复述或续写其中内容）\n"
                + "\n".join(summary_lines)
            )

        headline_lines = [
            f"第 {item.get('index')} 章：{item.get('headline')}"
            for item in (context.get("recent_headlines") or [])
            if isinstance(item, dict) and (item.get("headline") or "").strip()
        ]
        if headline_lines:
            sections.append("# 更早章节大事记\n" + "\n".join(headline_lines))

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

    Sourced from the top-level ``chapter_directive`` key plus the
    ``structured_prompt`` blueprint fields. Returns ``""`` (section omitted
    entirely) when every one of these is empty.
    """
    structured_prompt = context.get("structured_prompt") or {}
    lines: list[str] = []

    directive = context.get("chapter_directive")
    if isinstance(directive, str) and directive.strip():
        lines.append(f"本章创作指令：{directive.strip()}")

    goal = structured_prompt.get("chapter_goal")
    if isinstance(goal, str) and goal.strip():
        lines.append(f"本章目标：{goal.strip()}")

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

    must_happen = [item.strip() for item in (structured_prompt.get("must_happen") or []) if isinstance(item, str) and item.strip()]
    if must_happen:
        lines.append("必须发生：")
        lines.extend(f"- {item}" for item in must_happen)

    must_not_happen = [
        item.strip() for item in (structured_prompt.get("must_not_happen") or []) if isinstance(item, str) and item.strip()
    ]
    if must_not_happen:
        lines.append("不可发生：")
        lines.extend(f"- {item}" for item in must_not_happen)

    focus_traits = [item.strip() for item in (structured_prompt.get("focus_traits") or []) if isinstance(item, str) and item.strip()]
    if focus_traits:
        lines.append(f"聚焦特质：{'，'.join(focus_traits)}")

    extra_notes = structured_prompt.get("extra_notes")
    if isinstance(extra_notes, str) and extra_notes.strip():
        lines.append(f"补充说明：{extra_notes.strip()}")

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
