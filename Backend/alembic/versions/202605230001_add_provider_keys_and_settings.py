"""add provider_keys and system_settings

Revision ID: 202605230001
Revises: 202605220001
Create Date: 2026-05-23 00:00:00.000000
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605230001"
down_revision: str | None = "202605220001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "provider_keys",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("key_label", sa.Text(), nullable=False),
        sa.Column("provider_hint", sa.Text(), nullable=True),
        sa.Column("base_url", sa.Text(), nullable=False),
        sa.Column("api_key", sa.Text(), nullable=False),
        sa.Column("model_name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "system_settings",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=False),
        sa.Column(
            "active_provider_key_id",
            sa.String(length=36),
            sa.ForeignKey("provider_keys.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("id = 1", name="ck_system_settings_singleton"),
    )


def downgrade() -> None:
    op.drop_table("system_settings")
    op.drop_table("provider_keys")
