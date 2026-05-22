from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models.agent_log import AgentLog
from app.schemas.timeline import AgentLogRead

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/logs")
def list_agent_logs(
    chapter_id: str | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
) -> dict[str, list[AgentLogRead]]:
    query = select(AgentLog).order_by(AgentLog.created_at.desc()).limit(limit)
    if chapter_id:
        query = query.where(AgentLog.chapter_id == chapter_id)
    logs = db.scalars(query).all()
    return {"items": [AgentLogRead.model_validate(log) for log in logs]}
