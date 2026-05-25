"""add character.pending_field_highlights

Revision ID: 202605260001
Revises: 202605250003
Create Date: 2026-05-26 00:00:01.000000

v0.7 Phase B-fld (§5.B): field-level dot indicator state on Character.
``pending_field_highlights`` is a dict mapping ``live_fields`` top-level key
name → ISO-8601 timestamp string of the most recent Extractor patch. Frontend
renders a small red dot next to the corresponding field; the dot is cleared
automatically when the user PATCHes that key.

JSONB on PostgreSQL, plain JSON on SQLite — same variant pattern used by
``frozen_fields`` / ``live_fields`` / ``author_notes``.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "202605260001"
down_revision: str | None = "202605250003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

json_type = sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql")


def upgrade() -> None:
    # server_default '{}' backfills existing rows (same pattern as L-1
    # author_notes migration). Both SQLite and Postgres accept '{}' as a
    # valid JSON literal.
    op.add_column(
        "characters",
        sa.Column(
            "pending_field_highlights",
            json_type,
            nullable=False,
            server_default=sa.text("'{}'"),
        ),
    )
    # Defensive backfill in case any row ended up with NULL despite the
    # server_default (engine-dependent behaviour). Idempotent.
    op.execute(
        "UPDATE characters SET pending_field_highlights = '{}' "
        "WHERE pending_field_highlights IS NULL"
    )


def downgrade() -> None:
    op.drop_column("characters", "pending_field_highlights")
