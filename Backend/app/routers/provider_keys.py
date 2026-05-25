from __future__ import annotations

from fastapi import APIRouter, Depends, Path, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.errors import AppError, not_found
from app.models.common import utc_now
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.schemas.provider_key import (
    AGENT_ROLES,
    ActiveAgentKeyRead,
    ActiveAgentKeyUpdate,
    ActiveProviderKeyUpdate,
    AgentRole,
    ProviderKeyCreate,
    ProviderKeyRead,
    ProviderKeyUpdate,
    SystemSettingsRead,
    mask_api_key,
)

router = APIRouter(tags=["provider_keys"])

# v0.7 M-1: maps agent_role → corresponding column on system_settings. Used
# by the parameterised /settings/active_key/{agent_role} endpoint as a
# single source of truth, so adding a new Agent later only requires editing
# this dict + AGENT_ROLES + adding a new column on system_settings.
_AGENT_TO_SETTINGS_COLUMN: dict[AgentRole, str] = {
    "writer": "active_writer_key_id",
    "extractor": "active_extractor_key_id",
    "expander": "active_expander_key_id",
}


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
        agent_role=payload.agent_role,
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
    # Eagerly unbind from system_settings (generic + every per-agent pointer)
    # so the API contract stays valid even on backends where FK ON DELETE
    # SET NULL is not enforced (SQLite without PRAGMA foreign_keys=ON).
    settings_row = _get_or_create_system_settings(db)
    dirty = False
    if settings_row.active_provider_key_id == key.id:
        settings_row.active_provider_key_id = None
        dirty = True
    for column in _AGENT_TO_SETTINGS_COLUMN.values():
        if getattr(settings_row, column) == key.id:
            setattr(settings_row, column, None)
            dirty = True
    if dirty:
        settings_row.updated_at = utc_now()
    db.delete(key)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/settings/active_provider_key", response_model=SystemSettingsRead)
def get_active_provider_key(db: Session = Depends(get_db)) -> SystemSettingsRead:
    settings_row = _get_or_create_system_settings(db)
    active_id = settings_row.active_provider_key_id
    if active_id is None:
        return SystemSettingsRead(active_provider_key_id=None)
    key = db.get(ProviderKey, active_id)
    if key is None:
        # Stale FK (shouldn't normally happen, but treat as not-set).
        return SystemSettingsRead(active_provider_key_id=None)
    return _summary_for(key)


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
    return _summary_for(key)


# ----- Per-Agent active key endpoints (v0.7 M-1, §5.M) -----
#
# Design decision: a single parameterised endpoint pair, not six. The
# ``agent_role`` is constrained by FastAPI's Path regex so anything
# outside {writer, extractor, expander} returns a 422 from the validation
# layer (handled by app/errors.py → standard envelope, kind=validation).
# The endpoint pair is independent of the generic /active_provider_key
# pair, which is preserved unchanged for v0.6 backward compatibility.


@router.get("/settings/active_key/{agent_role}", response_model=ActiveAgentKeyRead)
def get_active_agent_key(
    agent_role: AgentRole = Path(..., pattern="^(writer|extractor|expander)$"),
    db: Session = Depends(get_db),
) -> ActiveAgentKeyRead:
    settings_row = _get_or_create_system_settings(db)
    column = _AGENT_TO_SETTINGS_COLUMN[agent_role]
    active_id: str | None = getattr(settings_row, column)
    if active_id is None:
        return ActiveAgentKeyRead(agent_role=agent_role, active_provider_key_id=None)
    key = db.get(ProviderKey, active_id)
    if key is None:
        # Stale FK (shouldn't happen under normal flow — delete clears it —
        # but be defensive in case of out-of-band deletion).
        return ActiveAgentKeyRead(agent_role=agent_role, active_provider_key_id=None)
    return _agent_summary_for(agent_role, key)


@router.put("/settings/active_key/{agent_role}", response_model=ActiveAgentKeyRead)
def set_active_agent_key(
    payload: ActiveAgentKeyUpdate,
    agent_role: AgentRole = Path(..., pattern="^(writer|extractor|expander)$"),
    db: Session = Depends(get_db),
) -> ActiveAgentKeyRead:
    settings_row = _get_or_create_system_settings(db)
    column = _AGENT_TO_SETTINGS_COLUMN[agent_role]
    # provider_key_id = None → explicit "clear back to generic fallback".
    if payload.provider_key_id is None:
        setattr(settings_row, column, None)
        settings_row.updated_at = utc_now()
        db.commit()
        return ActiveAgentKeyRead(agent_role=agent_role, active_provider_key_id=None)

    key = db.get(ProviderKey, payload.provider_key_id)
    if key is None:
        raise not_found("Provider key not found")
    # Honour the key's own ``agent_role`` declaration when present: a key
    # tagged 'extractor' cannot be activated for 'writer'. NULL agent_role
    # means "generic" and is allowed for any slot. This makes the
    # declaration meaningful — without this check it would be purely
    # cosmetic, and a misconfiguration (e.g. accidentally activating an
    # extractor key for the writer slot) would silently route Writer to
    # the wrong model.
    if key.agent_role is not None and key.agent_role != agent_role:
        raise AppError(
            "conflict",
            "Provider key is bound to a different agent_role",
            status_code=status.HTTP_409_CONFLICT,
            details={"key_agent_role": key.agent_role, "requested": agent_role},
        )
    setattr(settings_row, column, key.id)
    settings_row.updated_at = utc_now()
    db.commit()
    return _agent_summary_for(agent_role, key)


def _agent_summary_for(agent_role: AgentRole, key: ProviderKey) -> ActiveAgentKeyRead:
    return ActiveAgentKeyRead(
        agent_role=agent_role,
        active_provider_key_id=key.id,
        key_label=key.key_label,
        provider_hint=key.provider_hint,
        model_name=key.model_name,
        api_key_mask=mask_api_key(key.api_key),
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
        agent_role=key.agent_role,  # M-1
        created_at=key.created_at,
        updated_at=key.updated_at,
    )


def _summary_for(key: ProviderKey) -> SystemSettingsRead:
    """Flat active-key summary (plan §5.E.4).

    The renamed field ``api_key_mask`` makes it unambiguous at the wire level
    that this value is masked (e.g. ``****1234``) and never the full key.
    """
    return SystemSettingsRead(
        active_provider_key_id=key.id,
        key_label=key.key_label,
        provider_hint=key.provider_hint,
        model_name=key.model_name,
        api_key_mask=mask_api_key(key.api_key),
    )
