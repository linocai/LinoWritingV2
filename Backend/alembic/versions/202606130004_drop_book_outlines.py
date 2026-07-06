"""drop book_outlines (v1.3.0 JJ P5 — 去大纲化)

Revision ID: 202606130004
Revises: 202606130003
Create Date: 2026-07-06 00:00:00.000000

v1.3.0 JJ (去大纲化): the whole book-outline module is removed. The
Expander no longer reads a whole-book outline (P4 dropped the ``outline``
key from ``build_expander_context``); the ``BookOutline`` model, router and
schemas are gone (P5). The ``book_outlines`` table is therefore dead weight,
so drop it.

``downgrade`` recreates the table verbatim from 202606130001
(add_book_outlines) so this migration round-trips cleanly. **No row data is
restored** — the drop is intentionally destructive of the outline prose
(same pattern as v1.0.1's drop of the pairing tables). The pre-deploy data
insurance is a full pg_dump backup + a per-book ``outline_<book_id>.txt``
export (see PROJECT_PLAN §4 P5/P9), NOT this downgrade.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202606130004"
down_revision: str | None = "202606130003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_table("book_outlines")


def downgrade() -> None:
    # Recreated verbatim from 202606130001 (add_book_outlines) so this
    # migration round-trips cleanly. No row data is restored.
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
