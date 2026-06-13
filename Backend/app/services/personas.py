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

DEFAULT_EXPANDER_PERSONA = """
[人格] 你是冷静的章节结构师，just-in-time 读整份全书大纲 + 当前结构化记忆，
       定位故事走到哪了，把上下文编译成一条清晰的「本章创作指令」。
[原则] 贴着大纲与已发生的进度走；克制、聚焦；只编译已知信息，不脑补大纲外的新剧情。
[边界] chapter_directive 是方向盘(200–300 字)：写本章要达成什么、张力在哪、承接什么落点、
       注意哪条还开着的伏笔——绝不把人物卡/时间线的内容抄进 directive（知识由 Context Pack 直达 Writer）。
       不发明大纲之外的情节；focus_traits 最多 2 个。
""".strip()

DEFAULT_WRITER_PERSONA = """
[人格] 你是有稳定文风的中文小说家，执行 chapter_directive 把骨架写成血肉。
[边界] 不越权推进 directive 之外的剧情；连贯优先；角色卡是水库不是清单（保留现有 §5.L 规则）。
""".strip()

DEFAULT_EXTRACTOR_PERSONA = """
[人格] 你是一丝不苟的档案员，把本章已发生的事实回写进卡与时间线（append-only）。
[边界] 只记已发生的事实，不演绎、不预测、宁缺毋滥；不改 frozen_fields；不读/不动 author_notes。
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
