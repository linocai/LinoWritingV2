from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient
from app.services.personas import DEFAULT_PERSONAS, compose_system


EXTRACTOR_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "timeline_events": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "character_id": {"type": "string"},
                    "event_type": {
                        "type": "string",
                        "enum": [
                            "action",
                            "experience",
                            "relation_change",
                            "secret_learned",
                            "ability_gained",
                            "state_change",
                        ],
                    },
                    "event_text": {"type": "string"},
                },
                "required": ["character_id", "event_type", "event_text"],
            },
        },
        "character_updates": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "character_id": {"type": "string"},
                    # v0.7 B-fld (§5.B.2): field-level dot indicator. Extractor
                    # must list the top-level live_fields keys it patched so the
                    # frontend can render per-field red dots. Server falls back
                    # to ``live_fields_patch.keys()`` as the source of truth if
                    # this list disagrees with the patch.
                    "patch_keys": {
                        "type": "array",
                        "items": {"type": "string"},
                    },
                    "live_fields_patch": {"type": "object"},
                },
                "required": ["character_id", "live_fields_patch"],
            },
        },
    },
    "required": ["summary", "timeline_events", "character_updates"],
}


class ExtractorAgent:
    # v1.0.0 EE Phase 2 (§4.3 / §4.4) — fixed extraction mechanics. The persona
    # ([人格]/[边界], DB-stored & App-editable) is resolved by
    # ``get_persona(db, 'extractor')`` at the router and composed in front of
    # these rules at runtime (see ``compose_system``). Operational rules stay in
    # code; the schema is unchanged this Phase.
    OPERATIONAL_RULES = """
你是中文小说章节信息抽取助手。
从正文中抽取本章关键事件，按出场角色归属。
每条 timeline_events.event_text 只能一句话，建议不超过 60 字。
character_updates 只输出需要变化的 live_fields 子字段，未变化的不输出。
数组字段使用全量替换语义：你输出什么就是新值，不是追加。
对每个 character_update，请在 patch_keys 数组里列出本次 patch 修改的
live_fields 顶层 key 名（如 ["current_status", "knowledge"]）；用于前端字段级红点。
summary 需要 200 字内，第三人称客观叙述本章发生了什么。
summary 的**第一句**必须独立概括本章最重要的事件，且不超过 40 字——
这一句会被机械截取为全书大事记里本章的唯一条目，长期用于长程记忆；
其余内容按重要性递减展开。
不要修改 frozen_fields。
只返回合法 JSON object。
""".strip()

    # Backward-compat / regression surface: the default-composed system prompt.
    system_prompt = compose_system(DEFAULT_PERSONAS["extractor"], OPERATIONAL_RULES)

    def __init__(self, llm: LLMClient, persona: str | None = None) -> None:
        self.llm = llm
        self.system_prompt = compose_system(
            persona if persona is not None else DEFAULT_PERSONAS["extractor"],
            self.OPERATIONAL_RULES,
        )

    def extract(self, context: dict[str, Any]) -> dict[str, Any]:
        # v0.6+: model selection follows the active ProviderKey's ``model_name``;
        # the old per-agent ``model_name_fast`` override has been removed.
        return self.llm.complete_json(
            system=self.system_prompt,
            user=json.dumps(context, ensure_ascii=False, default=str),
            schema=EXTRACTOR_SCHEMA,
            temperature=0.2,
        )
