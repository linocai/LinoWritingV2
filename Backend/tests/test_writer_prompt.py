from __future__ import annotations

from typing import Any

from app.agents.writer import WriterAgent


class _CapturingLLM:
    """Captures the user message Writer hands to the LLM client."""

    def __init__(self) -> None:
        self.last_user: str | None = None
        self.last_system: str | None = None

    def complete(self, **kwargs: Any) -> str:  # pragma: no cover - unused here
        return ""

    def complete_json(self, **kwargs: Any) -> dict[str, Any]:  # pragma: no cover - unused here
        return {}

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):
        self.last_system = system
        self.last_user = user
        if False:
            yield ""


# ---- v1.3.4 快修 (作者实测报障) — 分节渲染 (JSON→中文文档) ------------------
#
# 线上实测 Writer 输入 83% 被前三章原文占据，模型把任务当素材续写导致大段跑
# 偏。修法：① Writer 彻底断原文（context_pack.py 不再有 recent_fulltext /
# style_samples）；② user 消息从一坨 JSON 改写成固定节序的中文文档
# (``_render_user_message``)。以下测试锁定节序、空节省略、以及各字段的正确
# 归属。


def test_writer_user_message_section_order_full_context():
    """A fully-populated context renders every section, in the fixed order:
    世界观设定 → 文风要求 → 前情梗概 → 更早章节大事记 → 上一章梗概 →
    在场角色 → 本章写作任务 → 交稿要求 (always last)."""
    llm = _CapturingLLM()
    context = {
        "world_setting": "雨城常年阴雨。",
        "style_directive": "克制、留白。",
        "chapter_directive": "本章把林夕推到抉择口。",
        "target_word_count": 2500,
        "structured_prompt": {
            "chapter_goal": "推进剧情",
            "scene_setting": "雨夜山洞",
            "narrative_pov": "third_person_limited",
            "must_happen": ["发现铜钱"],
            "must_not_happen": ["揭晓黑手"],
            "focus_traits": ["谨慎"],
            "extra_notes": "保持悬疑感",
        },
        "characters": [
            {
                "id": "c1",
                "name": "林夕",
                "role": "主角",
                "frozen_fields": {"core_traits": "谨慎"},
                "live_fields": {"current_status": "调查中"},
                "author_notes": {"motivation": "为妹妹复仇"},
            }
        ],
        "timelines": {"c1": [{"chapter_index": 2, "event_text": "发现旧信。"}]},
        "previous_chapter_summary": {"index": 3, "summary": "林夕跟丢了嫌疑人。"},
        "recent_summaries": [{"index": 1, "summary": "接下失踪案。"}, {"index": 2, "summary": "发现旧信。"}],
        "recent_headlines": [{"index": 0, "headline": "序章：退役回乡。"}],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    msg = llm.last_user

    headers = [
        "# 世界观设定（硬约束，正文不得违背）",
        "# 文风要求",
        "# 前情梗概（背景资料，非写作素材——不要展开、复述或续写其中内容）",
        "# 更早章节大事记",
        "# 上一章梗概（衔接点：本章从这个落点接续）",
        "# 在场角色（幕后参考，用于判断言行，不是清单）",
        "# 本章写作任务",
        "# 交稿要求",
    ]
    positions = [msg.index(header) for header in headers]
    assert positions == sorted(positions), "sections must appear in the fixed plan order"
    # 本章写作任务 is second-to-last, 交稿要求 is last (verbatim, not just present).
    assert msg.rstrip().endswith("抵达区间即完稿。")
    assert positions[-2] < positions[-1] < len(msg)


def test_writer_user_message_omits_empty_sections():
    """A bare context (no world_setting/style/summaries/characters/task
    fields) omits every optional section entirely — only the always-present
    「# 交稿要求」block survives."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
        "recent_headlines": [],
        "previous_chapter_summary": None,
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    msg = llm.last_user
    for header in (
        "# 世界观设定",
        "# 文风要求",
        "# 前情梗概",
        "# 更早章节大事记",
        "# 上一章梗概",
        "# 在场角色",
        "# 本章写作任务",
    ):
        assert header not in msg
    assert msg.strip() == (
        "# 交稿要求\n本章目标字数 2500–3500 字，完稿须落在该区间内。"
        "写到目标的八成时开始收束，抵达区间即完稿。"
    )


def test_writer_user_message_previous_chapter_summary_rendered_standalone():
    """previous_chapter_summary gets its own labelled section, distinct from
    (and not duplicated inside) recent_summaries."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {},
        "characters": [],
        "timelines": {},
        "previous_chapter_summary": {"index": 5, "summary": "林夕决定改走山路。"},
        "recent_summaries": [{"index": 3, "summary": "林夕接下失踪案。"}],
        "recent_headlines": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    msg = llm.last_user
    assert "# 上一章梗概（衔接点：本章从这个落点接续）" in msg
    assert "第 5 章：林夕决定改走山路。" in msg
    assert "# 前情梗概（背景资料，非写作素材——不要展开、复述或续写其中内容）" in msg
    assert "第 3 章：林夕接下失踪案。" in msg
    # No duplication: chapter 5's summary appears exactly once in the message.
    assert msg.count("林夕决定改走山路。") == 1


def test_writer_user_message_author_notes_present_but_labelled_backstage():
    """author_notes content DOES reach the user message (Writer needs it for
    backstage judgement), but under the "纯幕后，绝不入正文" label, never as
    a bare unlabelled field."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进", "focus_traits": ["谨慎"]},
        "characters": [
            {
                "id": "c1",
                "name": "林夕",
                "role": "主角",
                "frozen_fields": {"core_traits": "谨慎"},
                "live_fields": {},
                "author_notes": {"motivation": "为妹妹复仇"},
            }
        ],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    msg = llm.last_user
    assert "作者笔记（纯幕后，绝不入正文）：" in msg
    assert "为妹妹复仇" in msg
    assert "聚焦特质：谨慎" in msg


def test_writer_user_message_task_section_field_level_omission():
    """Within「# 本章写作任务」, individual fields are omitted line-by-line
    when absent (no must_not_happen here → no「不可发生」line), while present
    fields (chapter_goal / must_happen) still render."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进剧情", "must_happen": ["发现线索"]},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    msg = llm.last_user
    assert "本章目标：推进剧情" in msg
    assert "必须发生：" in msg and "- 发现线索" in msg
    assert "不可发生：" not in msg
    assert "聚焦特质：" not in msg
    assert "补充说明：" not in msg


# ---- Phase L-2 (§5.L.5) — system_prompt rewrite assertions --------------


def test_writer_system_prompt_teaches_show_dont_tell_rules():
    """The new prompt's whole point is to fix the trait-checklist habit.

    Lock in the load-bearing instructional bits so a future "small tweak"
    can't quietly delete them.
    """
    sp = WriterAgent.system_prompt
    # Section headers from §5.L.5.
    assert "角色卡使用规则" in sp
    assert "本章重点" in sp
    assert "author_notes" in sp  # survives via the DB-editable persona's [边界] line
    # Concept anchors that drive the model's framing.
    assert "幕后参考" in sp
    assert "聚焦特质" in sp  # v1.3.4: Chinese label replaces the raw focus_traits key
    # Show-don't-tell example pair must survive intact (both halves).
    assert "❌ 反例" in sp
    assert "✓ 正例" in sp
    # The "water reservoir" metaphor is what makes the model OK with not
    # using every trait — keep it.
    assert "水库" in sp
    # Hard guardrail on author_notes — the only thing standing between
    # author's private notes and them being narrated verbatim (v1.3.4:
    # rendered as「作者笔记」in the user message, not the raw JSON key).
    assert "绝不可有任何句子直接转述作者笔记" in sp


def test_writer_system_prompt_drops_old_strict_frozen_directive():
    """Regression: the v0.6 line that confused the model into thinking
    frozen_fields was a "must-display" checklist must be gone."""
    sp = WriterAgent.system_prompt
    assert "严格遵守 characters[*].frozen_fields" not in sp
    # The "冻结区不能漂移" wording in particular was misinterpreted by the
    # Writer as "every frozen field must appear on the page" — gone too.
    assert "冻结区不能漂移" not in sp


def test_writer_system_prompt_keeps_existing_plot_and_style_rules():
    """Don't regress the parts that were correct in v0.6 — must_happen /
    must_not_happen / timelines / target_word_count / output format.

    v1.3.4 快修: the rules now describe these via the Chinese section labels
    the model actually sees in the user message (「必须发生」/「不可发生」/
    「近期时间线」/「文风要求」/ 目标字数), not the raw JSON key names."""
    sp = WriterAgent.system_prompt
    assert "必须发生" in sp
    assert "不可发生" in sp
    assert "近期时间线" in sp
    assert "文风要求" in sp
    assert "目标字数" in sp
    assert "只输出正文纯文本" in sp


def test_writer_system_prompt_has_default_word_count_range_when_target_empty():
    """v1.3.1 (KK) P8: when target_word_count is empty/unset, the Writer must
    have a concrete default anchor (2500-3500 字) instead of the old bare
    "允许上下浮动 20%" wording (which had nothing to float around when
    target_word_count was itself empty). When a value IS provided, the ±20%
    rule still applies — locks both halves so a future edit can't silently
    drop the empty-case default."""
    sp = WriterAgent.system_prompt
    assert "2500" in sp and "3500" in sp
    assert "为空" in sp or "未提供" in sp
    assert "20%" in sp


def test_writer_system_prompt_describes_background_memory_sections():
    """v1.3.4 快修 (作者实测报障): the Writer used to receive ``recent_fulltext``
    (最近 3 章原文, ~1万字) with a rule that (implicitly) invited it to treat
    prior prose as material to draw from — line 上实测这坨原文占了 83% 的输入，
    模型把它当成了"待续写的素材"。The rule now describes only the THREE
    background-memory sections the Writer still gets (前情梗概/更早章节大事记/
    上一章梗概) and explicitly forbids expanding/restating/continuing them."""
    sp = WriterAgent.system_prompt
    assert "recent_fulltext" not in sp
    assert "前情梗概" in sp
    assert "更早章节大事记" in sp
    assert "上一章梗概" in sp
    assert "不要展开" in sp


def test_writer_user_message_carries_author_notes_when_present():
    """context_pack now includes characters[*].author_notes for Writer.

    This is a contract test: even though the Writer's user message is a
    rendered document (not a JSON dump), we lock in that author_notes
    content survives the round-trip under its「作者笔记」label so a future
    refactor can't quietly drop it.
    """
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进", "focus_traits": ["谨慎"]},
        "characters": [
            {
                "id": "c1",
                "name": "林夕",
                "frozen_fields": {"core_traits": "谨慎"},
                "live_fields": {},
                "author_notes": {"motivation": "为妹妹复仇"},
            }
        ],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "作者笔记" in llm.last_user
    assert "为妹妹复仇" in llm.last_user
    assert "聚焦特质：谨慎" in llm.last_user


def test_writer_system_prompt_declares_world_setting_hard_constraint():
    """v1.3.3 快修 (作者实测报障): ``world_setting`` was fed to the Writer since
    v1.0.0 (build_writer_context's first key) but neither the rules nor the
    persona ever mentioned it — the model treated the author's worldview as
    background noise and freely violated it. Locks a dedicated rules section
    naming the key and its hard-constraint semantics."""
    sp = WriterAgent.system_prompt
    assert "world_setting" in sp
    assert "硬约束" in sp
    assert "不得违背" in sp
    assert "不要编造" in sp or "不编造" in sp


def test_writer_user_message_trailing_word_count_block_with_target():
    """v1.3.3 快修: target_word_count buried inside the structured_prompt JSON
    was ignored in practice (2500 requested → 4000+ delivered). The user
    message now ends with an explicit「# 交稿要求」block carrying the concrete
    number and the ±20% window."""
    llm = _CapturingLLM()
    context = {
        "target_word_count": 2500,
        "structured_prompt": {"chapter_goal": "推进", "target_word_count": 2500},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "# 交稿要求" in llm.last_user
    assert "2500 字" in llm.last_user
    assert "2000" in llm.last_user and "3000" in llm.last_user
    # Trailing position: the block must be the last section.
    assert llm.last_user.rstrip().endswith("抵达区间即完稿。")


def test_writer_user_message_trailing_word_count_block_default_range():
    """No target (or a junk value) → the trailing block still appears, carrying
    the 2500–3500 default anchor instead of a computed window."""
    llm = _CapturingLLM()
    for junk in (None, 0, -100, True):
        context = {
            "target_word_count": junk,
            "structured_prompt": {"chapter_goal": "推进"},
            "characters": [],
            "timelines": {},
            "recent_summaries": [],
        }
        list(WriterAgent(llm).stream(context))
        assert llm.last_user is not None
        assert "# 交稿要求" in llm.last_user
        assert "2500–3500 字" in llm.last_user


def test_writer_user_message_word_count_block_falls_back_to_structured_prompt():
    """Bare contexts (tests / internal callers) without the lifted top-level
    key still resolve the target from structured_prompt."""
    llm = _CapturingLLM()
    context = {
        "structured_prompt": {"chapter_goal": "推进", "target_word_count": 3000},
        "characters": [],
        "timelines": {},
        "recent_summaries": [],
    }
    list(WriterAgent(llm).stream(context))
    assert llm.last_user is not None
    assert "3000 字" in llm.last_user
    assert "2400" in llm.last_user and "3600" in llm.last_user
