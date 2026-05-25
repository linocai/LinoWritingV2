from __future__ import annotations

from datetime import datetime

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
    agent_name: str | None = Query(default=None),
    before: datetime | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
) -> dict[str, list[AgentLogRead]]:
    """List agent_log entries, newest first.

    v0.7 §5.D / Phase D-log adds three new query params so the frontend can
    drive a paginated, filterable Admin Log panel:

    - ``agent_name`` filters by exact match (``expander`` / ``writer`` /
      ``extractor`` / ``admin_reset`` are the in-use values today). The list
      view in the app sends one of these strings when the user selects a
      Picker option; ``None`` (the default) returns every agent.
    - ``before`` is a cursor for "load more" scroll: rows older than this
      timestamp are returned. Combined with the ``created_at`` desc order
      this yields stable backward pagination without offset/limit drift
      when new logs are written concurrently.
    - ``chapter_id`` is kept from v0.5 (already used by chapter detail screens
      to scope to one chapter); the new filters apply on top of it.
    """
    query = select(AgentLog).order_by(AgentLog.created_at.desc()).limit(limit)
    if chapter_id:
        query = query.where(AgentLog.chapter_id == chapter_id)
    if agent_name:
        query = query.where(AgentLog.agent_name == agent_name)
    if before is not None:
        query = query.where(AgentLog.created_at < before)
    logs = db.scalars(query).all()
    return {"items": [AgentLogRead.model_validate(log) for log in logs]}
