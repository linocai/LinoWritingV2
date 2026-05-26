"""One-shot migration of legacy ``.env`` LLM credentials into ``provider_keys``.

The v0.5 deployment kept the Grok API key in ``.env``. v0.6 introduces an
in-app provider key registry. On first boot under v0.6 we detect a populated
``GROK_API_KEY`` env var combined with an empty ``provider_keys`` table and
seed exactly one record from the env, then mark it active in
``system_settings``. Subsequent boots see a non-empty table and do nothing.
"""
from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models.common import utc_now
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.services.encryption import encrypt_api_key


LEGACY_ENV_KEY_LABEL = "主 Grok (from .env)"


def migrate_env_provider_key(db: Session, settings: Settings) -> ProviderKey | None:
    """Seed a ProviderKey from ``.env`` if and only if the table is empty.

    Returns the newly created row, or ``None`` if nothing was done.
    """

    api_key = (settings.grok_api_key or "").strip()
    if not api_key:
        return None

    existing_count = db.scalar(select(func.count()).select_from(ProviderKey)) or 0
    if existing_count > 0:
        return None

    key = ProviderKey(
        key_label=LEGACY_ENV_KEY_LABEL,
        provider_hint="xai",
        base_url=settings.grok_base_url,
        # v0.8 T-1: this seeding path runs on first boot under v0.6→v0.8
        # upgrade and on fresh installs. Either way the on-disk value must
        # be ciphertext from the very first row.
        api_key=encrypt_api_key(api_key),
        model_name=settings.model_name,
    )
    db.add(key)
    db.flush()

    settings_row = db.get(SystemSettings, 1)
    if settings_row is None:
        settings_row = SystemSettings(id=1, active_provider_key_id=key.id)
        db.add(settings_row)
    else:
        settings_row.active_provider_key_id = key.id
        settings_row.updated_at = utc_now()

    db.commit()
    db.refresh(key)
    return key
