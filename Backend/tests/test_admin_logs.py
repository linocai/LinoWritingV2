"""Tests for GET /api/v1/admin/logs (§5.D / Phase D-log).

D-log adds two new query params on top of the v0.5 endpoint:

- ``agent_name`` exact-match filter (``expander`` / ``writer`` /
  ``extractor`` / ``admin_reset``). The frontend Picker in the new
  Settings → Agent 日志 tab sends one of these strings.
- ``before`` cursor for backward pagination (rows with
  ``created_at < before``). Combined with ``ORDER BY created_at DESC``
  this lets the frontend implement "load more" without offset drift.

These tests pin the new filters down so the frontend's AgentLogStore can
rely on them; the original "list newest first, default limit 50, scoped
by chapter_id" behaviour is already covered indirectly by callers and
isn't re-asserted here.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.models.agent_log import AgentLog


def _seed_logs(session_factory, *, rows: list[tuple[str, str, datetime]]) -> list[str]:
    """Insert rows directly via the same sessionmaker the TestClient uses.

    Each ``rows`` tuple is ``(agent_name, label, created_at)``; the label
    is stored in ``output_preview`` so individual logs can be identified
    in assertions without depending on UUID ordering.
    """
    ids: list[str] = []
    with session_factory() as session:
        for agent_name, label, created_at in rows:
            log = AgentLog(
                agent_name=agent_name,
                output_preview=label,
                created_at=created_at,
            )
            session.add(log)
            session.flush()
            ids.append(log.id)
        session.commit()
    return ids


def test_list_agent_logs_filter_by_agent_name(client, auth_headers, session_factory):
    now = datetime.now(timezone.utc)
    _seed_logs(
        session_factory,
        rows=[
            ("writer", "w1", now - timedelta(minutes=5)),
            ("extractor", "e1", now - timedelta(minutes=4)),
            ("writer", "w2", now - timedelta(minutes=3)),
            ("admin_reset", "r1", now - timedelta(minutes=2)),
            ("expander", "x1", now - timedelta(minutes=1)),
        ],
    )

    response = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
        params={"agent_name": "writer"},
    )
    assert response.status_code == 200
    items = response.json()["items"]
    assert len(items) == 2
    assert {item["output_preview"] for item in items} == {"w1", "w2"}
    assert all(item["agent_name"] == "writer" for item in items)

    # admin_reset is a valid filter value too (N's new agent_name)
    response = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
        params={"agent_name": "admin_reset"},
    )
    assert response.status_code == 200
    items = response.json()["items"]
    assert len(items) == 1
    assert items[0]["output_preview"] == "r1"


def test_list_agent_logs_before_cursor_paginates_backwards(
    client, auth_headers, session_factory
):
    now = datetime.now(timezone.utc)
    # 5 rows, evenly spaced minutes apart. Order desc by created_at:
    # e5, e4, e3, e2, e1.
    _seed_logs(
        session_factory,
        rows=[(f"writer", f"e{i}", now - timedelta(minutes=10 - i)) for i in range(1, 6)],
    )

    # First page: limit=2 → e5, e4
    page1 = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
        params={"limit": 2},
    ).json()["items"]
    assert [r["output_preview"] for r in page1] == ["e5", "e4"]

    # Second page: before=created_at of last row → e3, e2
    cursor = page1[-1]["created_at"]
    page2 = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
        params={"limit": 2, "before": cursor},
    ).json()["items"]
    assert [r["output_preview"] for r in page2] == ["e3", "e2"]

    # Final page: only e1 remains
    cursor = page2[-1]["created_at"]
    page3 = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
        params={"limit": 2, "before": cursor},
    ).json()["items"]
    assert [r["output_preview"] for r in page3] == ["e1"]
