"""add timeline_events.edited_at

Revision ID: 202605250003
Revises: 202605250002
Create Date: 2026-05-25 00:00:03.000000

v0.7 Phase C-tl (§5.C): TimelineEvent gains an ``edited_at`` audit column. The
column is NULL for events as originally written by the Extractor and is set to
``utc_now()`` the first (and every subsequent) time a user PATCHes ``event_text``
or ``event_type`` via ``PATCH /api/v1/timeline_events/{id}``. The frontend uses
its presence to render a small "已编辑" marker so the author can tell at a
glance which entries diverge from the Agent's original extraction.

The column is intentionally NULLable (no server_default) — back-filling every
existing row to ``utc_now()`` on migration would lose the very signal we're
trying to capture (existing rows pre-date this Phase and were never touched by
a human). Downgrade simply drops it.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605250003"
down_revision: str | None = "202605250002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "timeline_events",
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("timeline_events", "edited_at")
