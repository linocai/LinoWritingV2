"""drop device_tokens + pair_codes (v1.0.1)

Revision ID: 202606130003
Revises: 202606130002
Create Date: 2026-06-13 14:00:00.000000

v1.0.1: the v0.9 W multi-device pairing subsystem (per-device tokens +
6-digit pair codes) is removed in favour of a single fixed shared
``API_TOKEN`` compared in ``app.auth.require_bearer_token``. Both pairing
tables become dead weight, so drop them.

``downgrade`` recreates both tables verbatim from 202605260004 so the
migration is fully reversible (no data restoration — the rows carried only
ephemeral / now-unused credentials).
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202606130003"
down_revision: str | None = "202606130002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_table("pair_codes")
    op.drop_table("device_tokens")


def downgrade() -> None:
    # Recreated verbatim from 202605260004 (add_device_tokens) so this
    # migration round-trips cleanly. No row data is restored.
    op.create_table(
        "device_tokens",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("device_name", sa.Text(), nullable=False),
        sa.Column("token_ciphertext", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "pair_codes",
        sa.Column("code", sa.Text(), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("device_name", sa.Text(), nullable=True),
    )
