"""v1.3.0 (II) P2 — "导入人物卡" LLM parse: paste full character-sheet prose,
get back landed :class:`Character` rows.

This is a one-time tool action (not a writing-chain Agent), so the parsing
system prompt lives here as a module constant rather than in the DB persona
system (``services/personas.py``) — the user never needs to edit "how do you
parse a pasted character sheet", only the three writing-chain Agent
personalities (优化师/Writer/档案员). The LLM call itself reuses the
extractor's per-Agent key/client (``build_llm_client(db, agent_role="extractor")``)
since "structure prose into a character card" is the same shape of work the
Extractor Agent already does for in-chapter updates — just a standalone
invocation instead of a chapter-scoped one.
"""
from __future__ import annotations

import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.llm.base import LLMClient
from app.models.character import Character

# Response shape: a bare JSON array of character objects. `complete_json`
# only guarantees a top-level object, so the schema wraps the array under
# a single ``characters`` key (LLM instructed accordingly in the prompt);
# ``parse_characters_from_text`` unwraps it back to a plain list for callers.
CHARACTER_PARSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "characters": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "role": {"type": "string"},
                    "frozen_fields": {"type": "object"},
                    "author_notes": {"type": "object"},
                },
                "required": ["name"],
            },
        },
    },
    "required": ["characters"],
}

CHARACTER_PARSE_SYSTEM_PROMPT = """
你是小说角色设定解析助手。作者会粘贴一段或多段完整的人物设定文本，
你需要把其中每一个角色解析成结构化的角色卡。

规则：
1. 识别文本中出现的每一个独立角色，逐个输出。
2. 每个角色必须有 name（姓名），缺少姓名的角色跳过、不要虚构姓名。
3. role 是角色的身份/定位（如"主角""反派""配角"），可留空。
4. frozen_fields 是该角色的固定设定（背景、性格、外貌等开书时就定死的信息），
   把文本里能归类的设定项拆成 key: value 放进这个对象，key 用简短中文
   （如"背景"、"性格"、"外貌"），value 是对应描述。
5. author_notes 是作者写作时的幕后提示（动机、秘密、伤痛等不直接写进正文
   但影响角色行为的信息），同样拆成 key: value。
6. 只使用文本中明确给出的信息，不要凭空编造角色设定。
7. 不要输出 live_fields（角色的动态状态由后续剧情自动生成，此处不需要）。
8. 只返回合法 JSON object，形如 {"characters": [...]}。
""".strip()


def parse_characters_from_text(llm: LLMClient, raw_text: str) -> list[dict[str, Any]]:
    """Call the LLM and return the raw (unvalidated-against-DB) character
    dicts it produced. Raises ``LLMError`` (transport / malformed JSON,
    handled by ``openai_compatible.complete_json``) on failure — the router
    catches that and 502s. Returns ``[]`` when the LLM decides there are no
    parseable characters (not an error)."""
    result = llm.complete_json(
        system=CHARACTER_PARSE_SYSTEM_PROMPT,
        user=raw_text,
        schema=CHARACTER_PARSE_SCHEMA,
        temperature=0.2,
    )
    characters = result.get("characters")
    if not isinstance(characters, list):
        # Malformed/non-array shape — treat as upstream failure, same
        # posture as extractor_apply's "bad shape" 502s.
        raise ValueError("LLM parse response 'characters' is not an array")
    return characters


def _normalize_field_value(value: Any) -> str:
    """建议级修复 — plan §4 P2 contracts ``frozen_fields``/``author_notes``
    as ``dict[str, str]``, but the LLM occasionally returns a nested
    object/array (or a bare number/bool) as a field *value* despite the
    schema/prompt asking for flat key: value pairs. Landing that as-is
    stores a non-string in a ``str``-typed column round-trip, and the
    frontend's ``stringValue`` helper renders non-``.string`` JSONValue
    cases as an empty string — the field silently looks blank until the
    author overwrites it. Normalize every value to a readable string
    before it ever reaches the DB: dict/list → compact JSON text (CJK kept
    literal), everything else (int/float/bool/None) → ``str()``.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def _normalize_fields(fields: dict[str, Any]) -> dict[str, str]:
    return {
        key: _normalize_field_value(value)
        for key, value in fields.items()
        if isinstance(key, str)
    }


def land_parsed_characters(db: Session, book_id: str, items: list[dict[str, Any]]) -> list[Character]:
    """Validate + insert the LLM-parsed character dicts into ``characters``.

    Contract (PROJECT_PLAN §4 P2, pinned):
    - missing/blank ``name`` → skip that entry.
    - ``name`` (whitespace-trimmed, exact match) already exists on this book
      → skip (no overwrite, no duplicate). Also de-dupes *within* the same
      batch — the second occurrence of a repeated name in one LLM response
      is skipped the same way.
    - ``live_fields`` always lands empty (`{}`) — Extractor fills it later
      from story progress, parse-time doesn't pre-seed it.
    - Returns only the characters actually newly created, in input order.
    """
    existing_names = {
        name.strip()
        for (name,) in db.execute(
            select(Character.name).where(Character.book_id == book_id)
        ).all()
    }

    created: list[Character] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        name = name.strip()
        if name in existing_names:
            continue

        role = item.get("role")
        role = role.strip() if isinstance(role, str) and role.strip() else None
        frozen_fields = item.get("frozen_fields")
        frozen_fields = _normalize_fields(frozen_fields) if isinstance(frozen_fields, dict) else {}
        author_notes = item.get("author_notes")
        author_notes = _normalize_fields(author_notes) if isinstance(author_notes, dict) else {}

        character = Character(
            book_id=book_id,
            name=name,
            role=role,
            frozen_fields=frozen_fields,
            live_fields={},
            author_notes=author_notes,
        )
        db.add(character)
        created.append(character)
        # Guard within-batch duplicates too — a second occurrence of the
        # same name later in ``items`` must also be skipped.
        existing_names.add(name)

    if created:
        db.flush()
    return created
