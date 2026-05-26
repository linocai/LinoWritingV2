"""Tests for the v0.8 T-1 Alembic data migration (202605260003).

We don't drive these via the alembic CLI (too much process / config plumbing
for what is a self-contained data migration). Instead we set up the schema on
a fresh engine, populate rows in the shape the migration will see, and call
``upgrade()`` / ``downgrade()`` directly under a real Alembic
``MigrationContext`` so ``op.get_bind()`` resolves. This is exactly how the
Alembic docs recommend testing data migrations in isolation.

Three contracts pinned here:

1. Re-running ``upgrade()`` on an already-encrypted dataset is a no-op —
   double-encryption would break decryption irreversibly.
2. ``upgrade()`` rewrites pre-v0.8 plaintext rows into Fernet ciphertext.
3. ``downgrade()`` is the inverse — Fernet rows are decrypted back; the
   round-trip yields the original plaintext.
"""
from __future__ import annotations

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import text

from app.db import Base, make_engine
from app.services.encryption import (
    encrypt_api_key,
    is_fernet_ciphertext,
)


# Importing the migration module by file path. The version filename
# ``202605260003_encrypt_provider_keys.py`` isn't a valid Python identifier
# (leading digits), so we go through importlib.util to load it explicitly.
def _load_migration_module():
    import importlib.util
    from pathlib import Path

    migration_path = (
        Path(__file__).resolve().parent.parent
        / "alembic"
        / "versions"
        / "202605260003_encrypt_provider_keys.py"
    )
    spec = importlib.util.spec_from_file_location(
        "encrypt_provider_keys_migration", migration_path
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def migration_engine():
    """Fresh engine + schema with only the columns the migration touches.

    We deliberately use the project's full ``Base.metadata`` (not a shrunk
    one) so we don't end up testing against a schema that differs in subtle
    ways from production. The TEST_DATABASE_URL fixture honours an external
    DATABASE_URL, so this test runs on both SQLite and Postgres.
    """
    # Use a unique, ephemeral SQLite DB for the migration test so the rows
    # we insert don't collide with other tests sharing a TestClient/session.
    # Postgres path: TEST_DATABASE_URL points at the real cluster; each
    # test gets a fresh schema via create_all/drop_all.
    from tests.conftest import TEST_DATABASE_URL

    engine = make_engine(TEST_DATABASE_URL)
    Base.metadata.create_all(bind=engine)
    try:
        yield engine
    finally:
        Base.metadata.drop_all(bind=engine)
        engine.dispose()


def _run_migration(engine, direction: str) -> None:
    """Invoke the migration's ``upgrade()`` or ``downgrade()`` under a real
    Alembic MigrationContext so ``op.get_bind()`` returns this connection.

    Mirrors how ``alembic upgrade`` itself sets up the proxy: construct an
    ``Operations`` bound to a ``MigrationContext``, install it as the global
    proxy via ``_install_proxy`` (the same hook the alembic runner uses),
    then call the migration function, then tear the proxy down. We also
    issue ``connection.commit()`` after the block — Alembic's
    ``begin_transaction()`` resolves to a no-op (nullcontext) when the
    impl is non-transactional or the DDL flag says so, so the UPDATE
    statements would otherwise stay pending in autobegin and roll back
    when the connection closes. Explicit commit makes the test deterministic
    across SQLite + Postgres without relying on Alembic's internal flags.
    """
    module = _load_migration_module()

    with engine.connect() as connection:
        context = MigrationContext.configure(connection)
        operations = Operations(context)
        operations._install_proxy()
        try:
            with context.begin_transaction():
                if direction == "upgrade":
                    module.upgrade()
                else:
                    module.downgrade()
            connection.commit()
        finally:
            operations._remove_proxy()


def _insert_row(engine, row_id: str, api_key: str) -> None:
    """Insert a provider_keys row through raw SQL (no ORM encrypt hook)."""
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO provider_keys "
                "(id, key_label, provider_hint, base_url, api_key, model_name, "
                " created_at, updated_at) "
                "VALUES (:id, :label, :hint, :base, :api_key, :model, "
                " CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
            ),
            {
                "id": row_id,
                "label": f"row-{row_id}",
                "hint": "openai",
                "base": "https://example.test/v1",
                "api_key": api_key,
                "model": "gpt-4o",
            },
        )


def _read_api_key(engine, row_id: str) -> str:
    with engine.connect() as conn:
        return conn.execute(
            text("SELECT api_key FROM provider_keys WHERE id = :id"),
            {"id": row_id},
        ).scalar_one()


def test_migration_upgrades_plaintext(migration_engine) -> None:
    """An on-disk plaintext row must become Fernet ciphertext after upgrade,
    while preserving the round-trip back to the original plaintext."""
    from app.services.encryption import decrypt_api_key

    _insert_row(
        migration_engine,
        row_id="00000000-0000-0000-0000-000000000001",
        api_key="sk-plaintext-PRE-MIGRATION-1234",
    )
    assert (
        is_fernet_ciphertext(
            _read_api_key(
                migration_engine, "00000000-0000-0000-0000-000000000001"
            )
        )
        is False
    )

    _run_migration(migration_engine, direction="upgrade")

    after = _read_api_key(
        migration_engine, "00000000-0000-0000-0000-000000000001"
    )
    assert is_fernet_ciphertext(after), (
        f"Expected Fernet ciphertext after upgrade, got: {after!r}"
    )
    assert decrypt_api_key(after) == "sk-plaintext-PRE-MIGRATION-1234"


def test_migration_idempotent(migration_engine) -> None:
    """Running upgrade twice must yield the same value the first run did —
    i.e. the second pass MUST NOT re-encrypt the already-encrypted row.

    A double-encrypted token decrypts only to the inner ciphertext (a
    base64 blob), not to the original plaintext, which would break every
    LLM call after the second deploy. This test pins the idempotency guard.
    """
    _insert_row(
        migration_engine,
        row_id="00000000-0000-0000-0000-000000000002",
        api_key="sk-target-FOR-IDEMPOTENCE-5678",
    )

    _run_migration(migration_engine, direction="upgrade")
    once = _read_api_key(
        migration_engine, "00000000-0000-0000-0000-000000000002"
    )
    assert is_fernet_ciphertext(once)

    _run_migration(migration_engine, direction="upgrade")
    twice = _read_api_key(
        migration_engine, "00000000-0000-0000-0000-000000000002"
    )

    # The second pass must leave the row byte-for-byte unchanged. We assert
    # equality (not "still decrypts to plaintext"), because that's the
    # strongest signal that the idempotency guard fired — not the decrypt
    # path accidentally recovering from a double-encrypt.
    assert twice == once


def test_migration_skips_already_encrypted_rows(migration_engine) -> None:
    """A row that was inserted as ciphertext (e.g. by the v0.8 router itself)
    must not be touched by the migration. This is the "fresh install /
    no-op on subsequent deploys" path."""
    ciphertext = encrypt_api_key("sk-already-encrypted-NEW8")
    _insert_row(
        migration_engine,
        row_id="00000000-0000-0000-0000-000000000003",
        api_key=ciphertext,
    )

    _run_migration(migration_engine, direction="upgrade")
    after = _read_api_key(
        migration_engine, "00000000-0000-0000-0000-000000000003"
    )
    assert after == ciphertext


def test_migration_downgrade_restores_plaintext(migration_engine) -> None:
    """downgrade() walks Fernet rows and writes back plaintext.

    Useful as a sanity check of the inverse path. In production we never
    plan to actually call ``alembic downgrade`` against this revision, but
    the inverse symmetry is what makes the upgrade safe to deploy.
    """
    from app.services.encryption import decrypt_api_key

    ciphertext = encrypt_api_key("sk-roundtrip-DOWN-9012")
    _insert_row(
        migration_engine,
        row_id="00000000-0000-0000-0000-000000000004",
        api_key=ciphertext,
    )

    _run_migration(migration_engine, direction="downgrade")
    restored = _read_api_key(
        migration_engine, "00000000-0000-0000-0000-000000000004"
    )
    assert restored == "sk-roundtrip-DOWN-9012"
    # And the predicate now classifies this as "needs encryption again".
    assert is_fernet_ciphertext(restored) is False
