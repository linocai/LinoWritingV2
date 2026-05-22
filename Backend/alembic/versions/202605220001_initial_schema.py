"""initial schema

Revision ID: 202605220001
Revises:
Create Date: 2026-05-22 00:00:00.000000
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "202605220001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

json_type = sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql")


def upgrade() -> None:
    op.create_table(
        "books",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("cover_color", sa.Text(), nullable=True),
        sa.Column("world_setting", sa.Text(), nullable=True),
        sa.Column("style_directive", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_opened_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "characters",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), sa.ForeignKey("books.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("role", sa.Text(), nullable=True),
        sa.Column("frozen_fields", json_type, nullable=False),
        sa.Column("live_fields", json_type, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "chapters",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), sa.ForeignKey("books.id", ondelete="CASCADE"), nullable=False),
        sa.Column("index", sa.Integer(), nullable=False),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("user_prompt", sa.Text(), nullable=True),
        sa.Column("structured_prompt", json_type, nullable=True),
        sa.Column("draft_text", sa.Text(), nullable=True),
        sa.Column("summary", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("book_id", "index", name="uq_chapters_book_index"),
    )
    op.create_table(
        "timeline_events",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), sa.ForeignKey("books.id", ondelete="CASCADE"), nullable=False),
        sa.Column(
            "character_id",
            sa.String(length=36),
            sa.ForeignKey("characters.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("chapter_id", sa.String(length=36), sa.ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False),
        sa.Column("event_type", sa.String(length=32), nullable=False),
        sa.Column("event_text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_timeline_book_character_created", "timeline_events", ["book_id", "character_id", "created_at"])
    op.create_index("ix_timeline_book_chapter", "timeline_events", ["book_id", "chapter_id"])
    op.create_table(
        "agent_logs",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("chapter_id", sa.String(length=36), sa.ForeignKey("chapters.id", ondelete="SET NULL"), nullable=True),
        sa.Column("agent_name", sa.String(length=32), nullable=False),
        sa.Column("input_preview", sa.Text(), nullable=True),
        sa.Column("output_preview", sa.Text(), nullable=True),
        sa.Column("latency_ms", sa.Integer(), nullable=True),
        sa.Column("tokens_in", sa.Integer(), nullable=True),
        sa.Column("tokens_out", sa.Integer(), nullable=True),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("agent_logs")
    op.drop_index("ix_timeline_book_chapter", table_name="timeline_events")
    op.drop_index("ix_timeline_book_character_created", table_name="timeline_events")
    op.drop_table("timeline_events")
    op.drop_table("chapters")
    op.drop_table("characters")
    op.drop_table("books")
