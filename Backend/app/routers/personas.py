from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import i18n_not_found
from app.schemas.persona import AgentPersonaRead, AgentPersonaUpdate
from app.schemas.provider_key import AGENT_ROLES
from app.services import personas as persona_service

# v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §5.4) — agent persona CRUD.
# Three roles only (expander/writer/extractor); an unknown role is a 404
# (not_found), not a 422 — deliberately different from the per-Agent-key
# endpoints, which use a Path pattern. An empty system_prompt on PATCH is a
# 422 (enforced by AgentPersonaUpdate's validator).
router = APIRouter(tags=["agent-personas"])


@router.get("/agent-personas")
def list_agent_personas(db: Session = Depends(get_db)) -> dict[str, list[AgentPersonaRead]]:
    rows = persona_service.list_personas(db)
    return {"personas": [AgentPersonaRead.model_validate(row) for row in rows]}


@router.patch("/agent-personas/{agent_role}")
def patch_agent_persona(
    agent_role: str,
    payload: AgentPersonaUpdate,
    db: Session = Depends(get_db),
) -> dict[str, AgentPersonaRead]:
    _validate_role(agent_role)
    persona = persona_service.set_persona(db, agent_role, payload.system_prompt)
    return {"persona": AgentPersonaRead.model_validate(persona)}


@router.post("/agent-personas/{agent_role}/reset")
def reset_agent_persona(
    agent_role: str,
    db: Session = Depends(get_db),
) -> dict[str, AgentPersonaRead]:
    _validate_role(agent_role)
    persona = persona_service.reset_persona(db, agent_role)
    return {"persona": AgentPersonaRead.model_validate(persona)}


def _validate_role(agent_role: str) -> None:
    if agent_role not in AGENT_ROLES:
        raise i18n_not_found("agent_persona")
