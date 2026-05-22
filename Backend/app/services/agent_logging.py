from __future__ import annotations

import json
from time import perf_counter
from typing import Any

from sqlalchemy.orm import Session

from app.models.agent_log import AgentLog


def now_ms() -> float:
    return perf_counter()


def log_agent_call(
    db: Session,
    *,
    chapter_id: str | None,
    agent_name: str,
    input_data: Any,
    output_data: Any = None,
    started_at: float | None = None,
    error: str | None = None,
) -> None:
    latency_ms = int((perf_counter() - started_at) * 1000) if started_at is not None else None
    db.add(
        AgentLog(
            chapter_id=chapter_id,
            agent_name=agent_name,
            input_preview=_preview(input_data, limit=1024),
            output_preview=_preview(output_data, limit=2048),
            latency_ms=latency_ms,
            error=error,
        )
    )


def _preview(value: Any, *, limit: int) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, ensure_ascii=False, default=str)
    return text[:limit]
