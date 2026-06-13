from __future__ import annotations

from app.config import Settings
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.services.encryption import decrypt_api_key, is_fernet_ciphertext
from app.services.env_provider_migration import (
    LEGACY_ENV_KEY_LABEL,
    migrate_env_provider_key,
)
from tests.conftest import TEST_KEK_SECRET


def _settings_with_grok(api_key: str | None) -> Settings:
    return Settings(
        database_url="sqlite+pysqlite://",
        # v0.8 T-1: Settings requires a valid Fernet KEK; reuse the test one.
        kek_secret=TEST_KEK_SECRET,
        grok_api_key=api_key,
        grok_base_url="https://api.x.ai/v1",
        model_name="grok-4",
    )


def test_migration_seeds_provider_key_when_table_empty(db_session):
    settings = _settings_with_grok("sk-legacy-secret-1234")

    created = migrate_env_provider_key(db_session, settings)

    assert created is not None
    assert created.key_label == LEGACY_ENV_KEY_LABEL
    assert created.provider_hint == "xai"
    assert created.base_url == "https://api.x.ai/v1"
    # v0.8 T-1: on-disk api_key is now Fernet ciphertext. Verify both the
    # encrypted shape (storage contract) and that it decrypts to the original
    # plaintext (round-trip contract).
    assert is_fernet_ciphertext(created.api_key)
    assert decrypt_api_key(created.api_key) == "sk-legacy-secret-1234"
    assert created.model_name == "grok-4"

    # Exactly one row, and it is active in system_settings
    rows = db_session.query(ProviderKey).all()
    assert len(rows) == 1

    settings_row = db_session.get(SystemSettings, 1)
    assert settings_row is not None
    assert settings_row.active_provider_key_id == created.id


def test_migration_noop_when_env_key_missing(db_session):
    settings = _settings_with_grok(None)

    result = migrate_env_provider_key(db_session, settings)

    assert result is None
    assert db_session.query(ProviderKey).count() == 0
    assert db_session.get(SystemSettings, 1) is None


def test_migration_noop_when_provider_keys_not_empty(db_session):
    # Seed an existing row so the migration should skip
    existing = ProviderKey(
        key_label="already-here",
        provider_hint="openai",
        base_url="https://api.openai.com/v1",
        api_key="sk-existing",
        model_name="gpt-5",
    )
    db_session.add(existing)
    db_session.commit()

    settings = _settings_with_grok("sk-legacy-secret-1234")
    result = migrate_env_provider_key(db_session, settings)

    assert result is None
    # Still exactly one row (the pre-existing one), no overwrite
    rows = db_session.query(ProviderKey).all()
    assert len(rows) == 1
    assert rows[0].key_label == "already-here"
    # system_settings was not auto-populated
    assert db_session.get(SystemSettings, 1) is None


def test_migration_runs_only_once(db_session):
    settings = _settings_with_grok("sk-legacy-secret-1234")

    first = migrate_env_provider_key(db_session, settings)
    second = migrate_env_provider_key(db_session, settings)

    assert first is not None
    assert second is None
    assert db_session.query(ProviderKey).count() == 1
