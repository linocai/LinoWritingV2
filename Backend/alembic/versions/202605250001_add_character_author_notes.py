"""add character.author_notes

Revision ID: 202605250001
Revises: 202605230002
Create Date: 2026-05-25 00:00:01.000000

v0.7 Phase L-1 (§5.L.3): introduce a free-form ``author_notes`` JSON column on
``characters``. It stores the author's "actor cheat sheet" (motivation, past
wounds, secrets) — Writer is allowed to read it but the system prompt forbids
narrating it directly. JSONB on PostgreSQL, plain JSON on SQLite via the same
shared variant pattern used by ``frozen_fields`` / ``live_fields``.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "202605250001"
down_revision: str | None = "202605230002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

json_type = sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql")


def upgrade() -> None:
    # server_default '{}' backfills existing rows (both SQLite and Postgres
    # accept '{}' as a valid JSON literal for JSON/JSONB columns).
    op.add_column(
        "characters",
        sa.Column(
            "author_notes",
            json_type,
            nullable=False,
            server_default=sa.text("'{}'"),
        ),
    )
    # Defensive backfill in case any existing row somehow ended up with NULL
    # (e.g. on engines where add_column with server_default doesn't apply to
    # already-present rows). Idempotent.
    op.execute("UPDATE characters SET author_notes = '{}' WHERE author_notes IS NULL")


def downgrade() -> None:
    op.drop_column("characters", "author_notes")
