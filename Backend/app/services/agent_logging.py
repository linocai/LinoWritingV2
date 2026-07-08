from __future__ import annotations

import json
from time import perf_counter
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models.agent_log import AgentLog

# v1.2.0 (HH) P3 — 调用日志瘦身: retain only the most recent RETENTION_MAX
# `agent_logs` rows. Trigger is a **deterministic** module-level counter, not
# `random()` — a probabilistic trigger would make "write N rows, assert
# count <= RETENTION_MAX" tests flaky under CI. Every `log_agent_call` bumps
# `_write_count`; when it's a multiple of RETENTION_CHECK_EVERY, a cleanup
# DELETE is folded into the same call. Tests can `monkeypatch` both
# constants (e.g. RETENTION_CHECK_EVERY=1) to pin the trigger path.
RETENTION_CHECK_EVERY = 100
RETENTION_MAX = 500

_write_count = 0


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
    tokens_in: int | None = None,
    tokens_out: int | None = None,
) -> None:
    global _write_count
    latency_ms = int((perf_counter() - started_at) * 1000) if started_at is not None else None
    db.add(
        AgentLog(
            chapter_id=chapter_id,
            agent_name=agent_name,
            input_preview=_preview(input_data, limit=1024),
            output_preview=_preview(output_data, limit=2048),
            latency_ms=latency_ms,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            error=error,
        )
    )
    _write_count += 1
    if _write_count % RETENTION_CHECK_EVERY == 0:
        _enforce_retention(db)


def llm_usage_kwargs(llm: Any) -> dict[str, int | None]:
    """Pull ``{"tokens_in", "tokens_out"}`` off ``llm.last_usage`` for a
    ``log_agent_call(**...)`` call, right after using an LLM client.

    v1.3.4 快修 — 观测: tolerates LLM clients (test mocks, stubs) that don't
    expose ``last_usage`` at all, and clients where it's ``None`` (the
    upstream never reported usage for that call) — always returns a dict
    with both keys, values ``None`` in either case. Never raises.
    """
    usage = getattr(llm, "last_usage", None) or {}
    return {"tokens_in": usage.get("prompt_tokens"), "tokens_out": usage.get("completion_tokens")}


def _enforce_retention(db: Session) -> None:
    """Delete all but the RETENTION_MAX most-recent rows, in the same `db`
    session as the caller — no separate commit here. The DELETE rides along
    with whatever `db.commit()` the caller issues right after `log_agent_call`
    returns, so if the caller later rolls back, the cleanup rolls back too
    (safe: it never orphans a commit the caller didn't intend).

    `db.flush()` first: sessions here are `autoflush=False`, and the row
    `log_agent_call` just `db.add()`-ed is still only pending — without an
    explicit flush the Core-level SELECT/DELETE below can't see it, so it
    would never end up in the "keep newest RETENTION_MAX" set.
    """
    db.flush()
    keep_ids = select(AgentLog.id).order_by(AgentLog.created_at.desc()).limit(RETENTION_MAX)
    db.execute(delete(AgentLog).where(AgentLog.id.notin_(keep_ids)))


def _preview(value: Any, *, limit: int) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, ensure_ascii=False, default=str)
    return text[:limit]
