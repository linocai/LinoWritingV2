"""drop books.style_directive (v1.5.2 清理收口 — vestigial 全链删除)

Revision ID: 202607080001
Revises: 202606130004
Create Date: 2026-07-08 00:00:00.000000

v1.5.0 (NN) retired the global ``style_directive`` channel: the DB column,
``BookPatch``/``BookRead`` schema fields and ``books.py`` serialization were
left in place as a vestigial (dead) data pipe — the API still ACCEPTED writes
to it but nothing downstream read it. v1.5.2 (清理收口) deletes the whole chain,
including this column.

``downgrade`` re-adds the column as a nullable ``Text`` (verbatim from
202605220001 initial_schema). **No row data is restored** — the drop is
intentionally destructive of any residual directive text (the field has been
dead since v1.5.0; the book-wide style baseline now lives in the Writer
persona). Native ``ALTER TABLE … DROP/ADD COLUMN`` on both SQLite (3.35+) and
PostgreSQL; verified up/down/up reversible on a temp SQLite DB.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202607080001"
down_revision: str | None = "202606130004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_column("books", "style_directive")


def downgrade() -> None:
    # Re-added verbatim from 202605220001 (initial_schema) so this migration
    # round-trips cleanly. No row data is restored.
    op.add_column("books", sa.Column("style_directive", sa.Text(), nullable=True))
