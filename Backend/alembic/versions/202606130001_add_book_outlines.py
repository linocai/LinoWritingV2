"""add book_outlines (v1.0.0 EE Phase 1)

Revision ID: 202606130001
Revises: 202605260004
Create Date: 2026-06-13 00:00:01.000000

v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §3.1 / §3.4): the ~5000-word
plain-prose outline, one row per book. Pure add-table, no data backfill.

- ``book_id`` carries a UNIQUE constraint → singleton per book (1 book : 1
  outline) and an FK to ``books.id`` with ON DELETE CASCADE so deleting a
  book reaps its outline.
- ``raw_text`` is nullable — an outline row can exist (e.g. created by a
  PATCH-before-ingest) before the author has pasted any prose.
- ``DateTime(timezone=True)`` → TIMESTAMPTZ on Postgres, ISO-8601 strings on
  SQLite. Both backends round-trip the model's ``datetime`` fields. Runs on
  the shared ``alembic upgrade head`` path (PG + SQLite both green).
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202606130001"
down_revision: str | None = "202605260004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "book_outlines",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column(
            "book_id",
            sa.String(length=36),
            sa.ForeignKey("books.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("raw_text", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("book_id", name="uq_book_outlines_book_id"),
    )


def downgrade() -> None:
    op.drop_table("book_outlines")
