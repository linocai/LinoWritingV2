from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.agent_persona import AgentPersona
from app.models.common import utc_now
from app.schemas.provider_key import AGENT_ROLES, AgentRole

# v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §4.4 / §8) — code-level default
# persona prompts. They serve three roles:
#   1. seed source for the Alembic migration that creates ``agent_personas``;
#   2. reset source (``reset_persona`` writes the matching constant back);
#   3. DB-miss fallback (``get_persona`` returns the constant if the row is
#      somehow absent, so an Agent never ends up with an empty system prompt).
#
# Each persona is three-part: [人格] / [原则|边界]. The 边界 ("boundary")
#段 is the anti-drift guardrail —施工期 may微调用词 but its语义 must not
# weaken (plan §8).
#
# NOTE (Phase 1 scope): these constants are NOT yet wired into the three
# Agents' runtime system prompts — that re-route to ``get_persona`` is
# Phase 2. Phase 1 only stands up the table / service / endpoints + seed.

# v1.3.0 (II/JJ) P4 — 去大纲化: this code-level default persona is updated to
# match the new job description (no more "读整份全书大纲"). Note: this only
# changes the DEFAULT constant (seed / reset / DB-miss fallback source) — any
# DB persona row the author has already customised (incl. PATCHes made before
# this Phase landed) is untouched; see PROJECT_PLAN §4.2 user-facing checklist
# item for a "please self-review your persona for outline mentions" nudge.
DEFAULT_EXPANDER_PERSONA = """
[人格] 你是冷静的章节结构师。动笔前通读：世界观设定、近三章原文、更早章节的梗概与大事记、
       涉及角色的卡片与时间线、作者写的本章剧情——把这一切编译成一条清晰的「本章创作指令」。
[原则] 贴着作者的本章叙述走；克制、聚焦；只结构化＋核连续＋蒸馏已知信息，不发明作者没写的剧情。
       连续性核对含三面：不与世界观冲突、不与前文事实冲突、不与角色当前状态冲突；
       发现作者叙述与既有设定矛盾时，在 extra_notes 里提示，不擅自改写。
[边界] chapter_directive 是方向盘（200–300 字）：本章要达成什么、张力在哪、承接什么落点、
       哪条伏笔还开着——绝不把人物卡/时间线/世界观内容抄进去（知识另有通道直达 Writer）。
       不发明情节；focus_traits 最多 2 个。
""".strip()

DEFAULT_WRITER_PERSONA = """
[人格] 你是文风稳定的中文小说家，执行 chapter_directive 把骨架写成血肉。动笔前先内化
       世界观与角色，写出的每一段都活在这个世界的规则里。
[原则] 世界观是硬约束：能力体系、地理、历史、规则性设定一律以 world_setting 为准，不得违背、
       不得擅自扩写新设定；设定没讲清的地方宁可绕开，不编造。
       字数是交稿要求不是建议：按 target_word_count 分配全章节奏，临近目标即收束。
[边界] 不越权推进 directive 之外的剧情；连贯优先；角色卡是水库不是清单；author_notes 永不入正文。
""".strip()

DEFAULT_EXTRACTOR_PERSONA = """
[人格] 你是一丝不苟的档案员，把本章已发生的事实回写进角色卡与时间线（append-only），
       并写一段 200 字内的客观梗概。
[原则] 梗概第一句必须独立概括本章最重要的事件——这一句会长期作为全书大事记里本章的唯一条目。
       只记已发生的事实，不演绎、不预测、宁缺毋滥。
[边界] 不改 frozen_fields；不读/不动 author_notes；character_updates 只写真变化的字段。
""".strip()

DEFAULT_PERSONAS: dict[AgentRole, str] = {
    "expander": DEFAULT_EXPANDER_PERSONA,
    "writer": DEFAULT_WRITER_PERSONA,
    "extractor": DEFAULT_EXTRACTOR_PERSONA,
}


def compose_system(persona: str, operational_rules: str) -> str:
    """Join the (DB-editable) persona layer with the (code-fixed) mechanics.

    v1.0.0 EE Phase 2 (§4.4): an Agent's runtime ``system`` prompt is the
    persona ([人格]/[原则]/[边界], read from ``agent_personas``) followed by the
    Agent's fixed operational rules (schema/output mechanics, §5.L narrative
    guardrails). Persona is the steerable voice/boundary layer; operational
    rules are agent behaviour and never live in the DB. Either side may be
    empty/whitespace, in which case only the non-empty side is returned.
    """
    persona = (persona or "").strip()
    operational_rules = (operational_rules or "").strip()
    if persona and operational_rules:
        return f"{persona}\n\n{operational_rules}"
    return persona or operational_rules


def get_persona(db: Session, role: str) -> str:
    """Return the system prompt for ``role`` from the DB.

    Falls back to ``DEFAULT_PERSONAS[role]`` when the row is missing (DB-miss
    guard, never an empty prompt). Raises ``KeyError`` only for a role that
    isn't one of the known agent roles — callers validate the role before
    reaching here.
    """
    persona = db.get(AgentPersona, role)
    if persona is not None:
        return persona.system_prompt
    return DEFAULT_PERSONAS[role]


def list_personas(db: Session) -> list[AgentPersona]:
    """Return all persona rows in a stable role order (expander/writer/extractor)."""
    rows = db.scalars(select(AgentPersona)).all()
    by_role = {row.agent_role: row for row in rows}
    ordered: list[AgentPersona] = []
    for role in AGENT_ROLES:
        row = by_role.get(role)
        if row is None:
            # Defensive: a missing row (e.g. unmigrated DB) is materialised
            # in-memory from the default so the API still returns three rows.
            row = AgentPersona(
                agent_role=role,
                system_prompt=DEFAULT_PERSONAS[role],
                is_default=True,
                updated_at=utc_now(),
            )
        ordered.append(row)
    return ordered


def set_persona(db: Session, role: str, system_prompt: str) -> AgentPersona:
    """Overwrite the persona for ``role`` and mark it non-default.

    Caller must validate ``role`` ∈ AGENT_ROLES and that ``system_prompt`` is
    non-empty before calling. Upserts the row if it doesn't yet exist.
    """
    persona = db.get(AgentPersona, role)
    if persona is None:
        persona = AgentPersona(agent_role=role)
        db.add(persona)
    persona.system_prompt = system_prompt
    persona.is_default = False
    persona.updated_at = utc_now()
    db.commit()
    db.refresh(persona)
    return persona


def reset_persona(db: Session, role: str) -> AgentPersona:
    """Restore ``DEFAULT_PERSONAS[role]`` for ``role`` and mark it default."""
    persona = db.get(AgentPersona, role)
    if persona is None:
        persona = AgentPersona(agent_role=role)
        db.add(persona)
    persona.system_prompt = DEFAULT_PERSONAS[role]
    persona.is_default = True
    persona.updated_at = utc_now()
    db.commit()
    db.refresh(persona)
    return persona
