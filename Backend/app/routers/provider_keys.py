from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import not_found
from app.models.common import utc_now
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.schemas.provider_key import (
    ActiveProviderKeySummary,
    ActiveProviderKeyUpdate,
    ProviderKeyCreate,
    ProviderKeyRead,
    ProviderKeyUpdate,
    SystemSettingsRead,
    mask_api_key,
)

router = APIRouter(tags=["provider_keys"])


@router.get("/provider_keys")
def list_provider_keys(db: Session = Depends(get_db)) -> dict[str, list[ProviderKeyRead]]:
    keys = db.scalars(select(ProviderKey).order_by(ProviderKey.created_at)).all()
    return {"items": [_to_read(key) for key in keys]}


@router.post("/provider_keys", response_model=ProviderKeyRead, status_code=status.HTTP_201_CREATED)
def create_provider_key(payload: ProviderKeyCreate, db: Session = Depends(get_db)) -> ProviderKeyRead:
    key = ProviderKey(
        key_label=payload.key_label,
        provider_hint=payload.provider_hint,
        base_url=payload.base_url,
        api_key=payload.api_key,
        model_name=payload.model_name,
    )
    db.add(key)
    db.commit()
    db.refresh(key)
    return _to_read(key)


@router.patch("/provider_keys/{provider_key_id}", response_model=ProviderKeyRead)
def patch_provider_key(
    provider_key_id: str,
    payload: ProviderKeyUpdate,
    db: Session = Depends(get_db),
) -> ProviderKeyRead:
    key = _get_provider_key(db, provider_key_id)
    updates = payload.model_dump(exclude_unset=True)
    # api_key is only overwritten if explicitly provided in the request.
    for field, value in updates.items():
        setattr(key, field, value)
    key.updated_at = utc_now()
    db.commit()
    db.refresh(key)
    return _to_read(key)


@router.delete("/provider_keys/{provider_key_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_provider_key(provider_key_id: str, db: Session = Depends(get_db)) -> Response:
    key = _get_provider_key(db, provider_key_id)
    # Eagerly unbind from system_settings so the API contract stays valid
    # even on backends where FK ON DELETE SET NULL is not enforced.
    settings_row = _get_or_create_system_settings(db)
    if settings_row.active_provider_key_id == key.id:
        settings_row.active_provider_key_id = None
        settings_row.updated_at = utc_now()
    db.delete(key)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/settings/active_provider_key", response_model=SystemSettingsRead)
def get_active_provider_key(db: Session = Depends(get_db)) -> SystemSettingsRead:
    settings_row = _get_or_create_system_settings(db)
    active_id = settings_row.active_provider_key_id
    if active_id is None:
        return SystemSettingsRead(active_provider_key_id=None, active_provider_key=None)
    key = db.get(ProviderKey, active_id)
    if key is None:
        # Stale FK (shouldn't normally happen, but treat as not-set).
        return SystemSettingsRead(active_provider_key_id=None, active_provider_key=None)
    return SystemSettingsRead(
        active_provider_key_id=key.id,
        active_provider_key=_to_summary(key),
    )


@router.put("/settings/active_provider_key", response_model=SystemSettingsRead)
def set_active_provider_key(
    payload: ActiveProviderKeyUpdate,
    db: Session = Depends(get_db),
) -> SystemSettingsRead:
    key = db.get(ProviderKey, payload.provider_key_id)
    if key is None:
        raise not_found("Provider key not found")
    settings_row = _get_or_create_system_settings(db)
    settings_row.active_provider_key_id = key.id
    settings_row.updated_at = utc_now()
    db.commit()
    return SystemSettingsRead(
        active_provider_key_id=key.id,
        active_provider_key=_to_summary(key),
    )


def _get_provider_key(db: Session, provider_key_id: str) -> ProviderKey:
    key = db.get(ProviderKey, provider_key_id)
    if key is None:
        raise not_found("Provider key not found")
    return key


def _get_or_create_system_settings(db: Session) -> SystemSettings:
    settings_row = db.get(SystemSettings, 1)
    if settings_row is None:
        settings_row = SystemSettings(id=1, active_provider_key_id=None)
        db.add(settings_row)
        db.flush()
    return settings_row


def _to_read(key: ProviderKey) -> ProviderKeyRead:
    return ProviderKeyRead(
        id=key.id,
        key_label=key.key_label,
        provider_hint=key.provider_hint,
        base_url=key.base_url,
        api_key=mask_api_key(key.api_key),
        model_name=key.model_name,
        created_at=key.created_at,
        updated_at=key.updated_at,
    )


def _to_summary(key: ProviderKey) -> ActiveProviderKeySummary:
    return ActiveProviderKeySummary(
        id=key.id,
        key_label=key.key_label,
        provider_hint=key.provider_hint,
        model_name=key.model_name,
        api_key=mask_api_key(key.api_key),
    )
