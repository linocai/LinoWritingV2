"""encrypt provider_keys.api_key (Fernet)

Revision ID: 202605260003
Revises: 202605260002
Create Date: 2026-05-26 12:00:00.000000

v0.8 Phase T-1 (§5.T): data-only migration that walks every row in
``provider_keys`` and rewrites the ``api_key`` column with a Fernet ciphertext
when the on-disk value is still plaintext from a pre-v0.8 install. The column
type does NOT change — Fernet output is url-safe base64 ASCII (``gAAAAA...``)
which fits the existing ``Text`` column. After this runs, no plaintext API
token should remain anywhere in the database.

Idempotency:
The migration uses ``is_fernet_ciphertext`` as a per-row predicate before
re-encrypting, so running ``alembic upgrade head`` twice produces the same
end-state on the second run as the first. This matters for two reasons:
1. Alembic re-runs on aborted deploys are routine; double-encrypting would
   break decryption forever.
2. The HZ deploy script will run ``alembic upgrade head`` as part of every
   release — we don't want it to chew at the rows it already encrypted.

KEK sourcing & circular-import avoidance:
This module does NOT import ``app.config`` or ``app.services.encryption`` at
the top level. Alembic's migration environment loads modules during
``script.py.mako``-style introspection long before the Pydantic Settings has
been instantiated; pulling in ``app.config`` would either short-circuit on a
missing KEK env or cache a Settings built from the wrong env. Instead we
read ``KEK_SECRET`` directly from ``os.environ`` inside ``upgrade()`` /
``downgrade()`` and instantiate Fernet locally. A missing KEK at migration
time aborts with a clear RuntimeError rather than masking the failure as a
Pydantic ValidationError from a layer that the operator wouldn't be looking
at during ``alembic upgrade``.

Downgrade:
Re-decrypts every Fernet row back to plaintext. Useful only for testing /
rollback of T-1 itself; a successful upgrade should be considered terminal
in any production deployment.
"""
from __future__ import annotations

import os
from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "202605260003"
down_revision: str | None = "202605260002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


# Inlined copy of the cipher predicate so this migration does not depend on
# the app package's import graph (and stays runnable even after T-1 code is
# refactored later). Mirrors ``app.services.encryption.is_fernet_ciphertext``.
def _looks_like_fernet(value: str) -> bool:
    import base64
    import binascii

    if not value:
        return False
    try:
        raw = base64.urlsafe_b64decode(value.encode("ascii"))
    except (binascii.Error, ValueError, UnicodeEncodeError):
        return False
    if len(raw) < 57:
        return False
    return raw[0] == 0x80


def _build_cipher():
    """Construct a Fernet instance from ``KEK_SECRET`` in the current env.

    Local import of ``cryptography.fernet`` so a stale Alembic invocation
    that doesn't need this migration (e.g. ``alembic history``) still works
    even on a host that hasn't installed the package yet.
    """
    from cryptography.fernet import Fernet  # local import; see module docstring

    kek = os.environ.get("KEK_SECRET")
    if not kek:
        raise RuntimeError(
            "KEK_SECRET env var is required to run the provider_keys "
            "encryption migration. Set it before invoking `alembic upgrade`. "
            "Generate with: "
            'python -c "from cryptography.fernet import Fernet; '
            'print(Fernet.generate_key().decode())"'
        )
    return Fernet(kek.encode("ascii"))


def upgrade() -> None:
    bind = op.get_bind()
    # Fetch every row up-front into a Python list so the cursor is closed
    # before we start issuing UPDATEs (some drivers/dialects don't like
    # interleaving on the same connection).
    rows = bind.execute(sa.text("SELECT id, api_key FROM provider_keys")).fetchall()
    if not rows:
        return
    cipher = _build_cipher()
    update_stmt = sa.text(
        "UPDATE provider_keys SET api_key = :api_key WHERE id = :id"
    )
    for row in rows:
        row_id = row[0]
        existing = row[1] or ""
        # Idempotency guard — skip rows that already look like Fernet tokens.
        # This is what makes a re-run of ``alembic upgrade`` safe.
        if _looks_like_fernet(existing):
            continue
        ciphertext = cipher.encrypt(existing.encode("utf-8")).decode("ascii")
        bind.execute(update_stmt, {"api_key": ciphertext, "id": row_id})


def downgrade() -> None:
    bind = op.get_bind()
    rows = bind.execute(sa.text("SELECT id, api_key FROM provider_keys")).fetchall()
    if not rows:
        return
    cipher = _build_cipher()
    update_stmt = sa.text(
        "UPDATE provider_keys SET api_key = :api_key WHERE id = :id"
    )
    for row in rows:
        row_id = row[0]
        existing = row[1] or ""
        # Skip rows already plaintext (left in place by an earlier partial
        # downgrade) — keeps this side symmetric / idempotent with upgrade.
        if not _looks_like_fernet(existing):
            continue
        plaintext = cipher.decrypt(existing.encode("ascii")).decode("utf-8")
        bind.execute(update_stmt, {"api_key": plaintext, "id": row_id})
