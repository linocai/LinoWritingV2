"""drop characters.frozen_fields.voice key

Revision ID: 202605260002
Revises: 202605260001
Create Date: 2026-05-26 10:00:00.000000

v0.7.1 — the "voice" / "说话方式" frozen scalar was removed from the
recommended character-card schema (see §5.L). The field name invited the
Writer to copy "口头禅「啧」" verbatim into prose every chapter — the exact
narrate-the-card anti-pattern §5.L set out to kill. Scrub any stale
``frozen_fields["voice"]`` value from existing rows so the field never reaches
the Writer/Expander payload going forward.

Idempotent: rows without ``voice`` are untouched. Both SQLite and Postgres
support the operation natively, just with different syntax.

Downgrade is a no-op — we can't recover the deleted text, and re-adding an
empty ``voice: ""`` key would be visible noise.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "202605260002"
down_revision: str | None = "202605260001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    bind = op.get_bind()
    dialect = bind.dialect.name
    if dialect == "postgresql":
        # JSONB `-` operator removes the top-level key. ``frozen_fields ? 'voice'``
        # short-circuits rows without the key so we don't churn unrelated data.
        op.execute(
            "UPDATE characters SET frozen_fields = frozen_fields - 'voice' "
            "WHERE frozen_fields ? 'voice'"
        )
    elif dialect == "sqlite":
        # ``json_remove`` is a no-op if the path doesn't exist, so the WHERE
        # filter is only a perf optimisation. Kept for parity with the
        # Postgres branch above.
        op.execute(
            "UPDATE characters "
            "SET frozen_fields = json_remove(frozen_fields, '$.voice') "
            "WHERE json_extract(frozen_fields, '$.voice') IS NOT NULL"
        )
    else:  # pragma: no cover - defensive; we ship on SQLite + Postgres only
        raise RuntimeError(f"Unsupported dialect for voice cleanup: {dialect}")


def downgrade() -> None:
    # Data loss is intentional — no meaningful inverse.
    pass
