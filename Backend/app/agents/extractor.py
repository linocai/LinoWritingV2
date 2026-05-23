from __future__ import annotations

import json
from typing import Any

from app.llm.base import LLMClient


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
                    "live_fields_patch": {"type": "object"},
                },
                "required": ["character_id", "live_fields_patch"],
            },
        },
    },
    "required": ["summary", "timeline_events", "character_updates"],
}


class ExtractorAgent:
    system_prompt = """
你是中文小说章节信息抽取助手。
从正文中抽取本章关键事件，按出场角色归属。
每条 timeline_events.event_text 只能一句话，建议不超过 60 字。
character_updates 只输出需要变化的 live_fields 子字段，未变化的不输出。
数组字段使用全量替换语义：你输出什么就是新值，不是追加。
summary 需要 200 字内，第三人称客观叙述本章发生了什么。
不要修改 frozen_fields。
只返回合法 JSON object。
""".strip()

    def __init__(self, llm: LLMClient) -> None:
        self.llm = llm

    def extract(self, context: dict[str, Any]) -> dict[str, Any]:
        # v0.6+: model selection follows the active ProviderKey's ``model_name``;
        # the old per-agent ``model_name_fast`` override has been removed.
        return self.llm.complete_json(
            system=self.system_prompt,
            user=json.dumps(context, ensure_ascii=False, default=str),
            schema=EXTRACTOR_SCHEMA,
            temperature=0.2,
        )
