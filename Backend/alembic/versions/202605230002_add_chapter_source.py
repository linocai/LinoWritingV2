"""add chapter.source

Revision ID: 202605230002
Revises: 202605230001
Create Date: 2026-05-23 00:00:01.000000
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605230002"
down_revision: str | None = "202605230001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Add column with server-side default so existing rows backfill to 'agent'.
    op.add_column(
        "chapters",
        sa.Column(
            "source",
            sa.Text(),
            nullable=False,
            server_default=sa.text("'agent'"),
        ),
    )
    # Explicit backfill (idempotent — server_default already handled existing rows
    # on most engines, but we do this defensively for SQLite/older Postgres).
    op.execute("UPDATE chapters SET source = 'agent' WHERE source IS NULL")


def downgrade() -> None:
    op.drop_column("chapters", "source")
