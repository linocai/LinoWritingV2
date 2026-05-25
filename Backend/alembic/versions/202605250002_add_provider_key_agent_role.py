"""add provider_keys.agent_role + system_settings per-agent active keys

Revision ID: 202605250002
Revises: 202605250001
Create Date: 2026-05-25 00:00:02.000000

v0.7 Phase M-1 (§5.M.3): introduce per-Agent LLM key selection. Each
``provider_keys`` row may declare which Agent it is intended for via the
nullable ``agent_role`` column (``'writer'`` | ``'extractor'`` | ``'expander'``
or NULL = generic). ``system_settings`` gains three independent active
pointers — one per Agent — that fall back to the existing generic
``active_provider_key_id`` when unset. v0.6 deployments with all three new
pointers NULL behave identically to v0.6 (factory fall-back chain). See §5.M.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605250002"
down_revision: str | None = "202605250001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "provider_keys",
        sa.Column("agent_role", sa.Text(), nullable=True),
    )
    # Three per-agent FK pointers on the singleton system_settings row.
    # SQLite's batch_alter_table is required because plain ALTER TABLE ADD
    # COLUMN cannot declare a foreign key on SQLite, and the dev DB is SQLite.
    # On PostgreSQL the batch op is a no-op around the same DDL.
    with op.batch_alter_table("system_settings") as batch_op:
        batch_op.add_column(
            sa.Column("active_writer_key_id", sa.String(length=36), nullable=True)
        )
        batch_op.add_column(
            sa.Column("active_extractor_key_id", sa.String(length=36), nullable=True)
        )
        batch_op.add_column(
            sa.Column("active_expander_key_id", sa.String(length=36), nullable=True)
        )
        batch_op.create_foreign_key(
            "fk_system_settings_active_writer_key",
            "provider_keys",
            ["active_writer_key_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch_op.create_foreign_key(
            "fk_system_settings_active_extractor_key",
            "provider_keys",
            ["active_extractor_key_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch_op.create_foreign_key(
            "fk_system_settings_active_expander_key",
            "provider_keys",
            ["active_expander_key_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    with op.batch_alter_table("system_settings") as batch_op:
        batch_op.drop_constraint(
            "fk_system_settings_active_expander_key", type_="foreignkey"
        )
        batch_op.drop_constraint(
            "fk_system_settings_active_extractor_key", type_="foreignkey"
        )
        batch_op.drop_constraint(
            "fk_system_settings_active_writer_key", type_="foreignkey"
        )
        batch_op.drop_column("active_expander_key_id")
        batch_op.drop_column("active_extractor_key_id")
        batch_op.drop_column("active_writer_key_id")
    op.drop_column("provider_keys", "agent_role")
