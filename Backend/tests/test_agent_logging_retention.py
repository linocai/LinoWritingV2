"""Tests for v1.2.0 (HH) P3 — `agent_logs` retention (调用日志瘦身).

`log_agent_call` now folds a retention DELETE into the caller's own
transaction once a deterministic write counter crosses
`RETENTION_CHECK_EVERY`. These tests monkeypatch both module constants down
to small values so the trigger path is exercised deterministically (no
`random()`, no reliance on hitting the real default of 100/500 rows).
"""
from __future__ import annotations

from typing import Any

import app.services.agent_logging as agent_logging
from app.models.agent_log import AgentLog
from app.services.agent_logging import log_agent_call


def _write_n(session_factory, n: int, *, label_prefix: str = "row") -> None:
    """Mirror the real caller pattern: one `log_agent_call` + `db.commit()`
    per row, each in its own session (matches how chapters.py calls it —
    log then commit, not a single batch transaction)."""
    for i in range(n):
        with session_factory() as session:
            log_agent_call(
                session,
                chapter_id=None,
                agent_name="writer",
                input_data={"i": i},
                output_data=f"{label_prefix}-{i}",
            )
            session.commit()


def test_retention_triggers_deterministically_at_check_every(
    session_factory, monkeypatch: Any
) -> None:
    """Trigger is a modulo counter, not chance: writing exactly
    RETENTION_CHECK_EVERY rows must clean up, and nothing short of that
    boundary should."""
    monkeypatch.setattr(agent_logging, "_write_count", 0)
    monkeypatch.setattr(agent_logging, "RETENTION_CHECK_EVERY", 5)
    monkeypatch.setattr(agent_logging, "RETENTION_MAX", 3)

    # 4 rows: below the check boundary, no cleanup should have run yet.
    _write_n(session_factory, 4)
    with session_factory() as session:
        assert session.query(AgentLog).count() == 4

    # 5th row crosses RETENTION_CHECK_EVERY=5 → cleanup fires, trims to
    # RETENTION_MAX=3.
    _write_n(session_factory, 1, label_prefix="row5")
    with session_factory() as session:
        assert session.query(AgentLog).count() == 3


def test_retention_keeps_most_recent_rows(session_factory, monkeypatch: Any) -> None:
    """After cleanup fires, the newest RETENTION_MAX rows (by created_at)
    survive and the oldest ones are gone."""
    monkeypatch.setattr(agent_logging, "_write_count", 0)
    monkeypatch.setattr(agent_logging, "RETENTION_CHECK_EVERY", 10)
    monkeypatch.setattr(agent_logging, "RETENTION_MAX", 4)

    _write_n(session_factory, 10)

    with session_factory() as session:
        remaining = session.query(AgentLog).order_by(AgentLog.created_at.asc()).all()
        assert len(remaining) == 4
        previews = [row.output_preview for row in remaining]
        # The 6 oldest (row-0..row-5) must be gone; the 4 newest survive.
        assert previews == ["row-6", "row-7", "row-8", "row-9"]


def test_retention_does_not_fire_between_checkpoints(
    session_factory, monkeypatch: Any
) -> None:
    """Writes that don't land on a RETENTION_CHECK_EVERY multiple must not
    trigger cleanup — confirms the trigger is exactly the modulo boundary,
    not "whenever count exceeds max"."""
    monkeypatch.setattr(agent_logging, "_write_count", 0)
    monkeypatch.setattr(agent_logging, "RETENTION_CHECK_EVERY", 100)
    monkeypatch.setattr(agent_logging, "RETENTION_MAX", 2)

    # Write more rows than RETENTION_MAX but fewer than RETENTION_CHECK_EVERY:
    # cleanup must not have fired, even though we're well over RETENTION_MAX.
    _write_n(session_factory, 20)
    with session_factory() as session:
        assert session.query(AgentLog).count() == 20
