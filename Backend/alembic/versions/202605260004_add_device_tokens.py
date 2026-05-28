"""add device_tokens + pair_codes (v0.9 W-1)

Revision ID: 202605260004
Revises: 202605260003
Create Date: 2026-05-26 16:00:00.000000

v0.9 Phase W-1 (§5.W.3): per-device authentication. Replaces the single
``API_TOKEN`` env-var model with one row per paired device in
``device_tokens`` plus a short-lived ``pair_codes`` staging table.

Why two tables (not one with a ``status`` enum):
- ``pair_codes`` rows churn every 10 minutes and never carry secrets;
  ``device_tokens`` rows live forever and carry Fernet ciphertext. Keeping
  them split makes the audit story (who's logged in / who was ever logged in)
  trivially obvious to a future reviewer.

Why no FK between them:
- ``pair_codes.device_name`` is captured at confirm-time purely for audit; the
  pair_code is consumed on success and its only handoff to the device_token
  is the random Fernet plaintext, which deliberately never crosses tables.

TIMESTAMP variance:
- ``DateTime(timezone=True)`` maps to ``TIMESTAMPTZ`` on Postgres and to
  ``DATETIME`` on SQLite (SQLite has no real tz support; SQLAlchemy stores
  ISO-8601 strings). Both backends round-trip the ``datetime`` objects the
  models expect.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605260004"
down_revision: str | None = "202605260003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "device_tokens",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("device_name", sa.Text(), nullable=False),
        # Fernet ciphertext only; never raw token. See app/auth.py for the
        # decrypt-and-match walk that turns this back into a Bearer match.
        sa.Column("token_ciphertext", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "pair_codes",
        # 6 hex/ASCII chars max; Text is fine and dialect-portable.
        sa.Column("code", sa.Text(), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("device_name", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("pair_codes")
    op.drop_table("device_tokens")
