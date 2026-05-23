from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import UtcDatetime


def mask_api_key(api_key: str) -> str:
    """Return the api_key masked as `****xxxx` (last 4 chars).

    If the key is shorter than 4 chars, the full available tail is exposed
    after the `****` prefix. Empty values produce a bare `****`.
    """

    tail = api_key[-4:] if api_key else ""
    return f"****{tail}"


class ProviderKeyCreate(BaseModel):
    key_label: str = Field(min_length=1)
    provider_hint: str | None = None
    base_url: str = Field(min_length=1)
    api_key: str = Field(min_length=1)
    model_name: str = Field(min_length=1)


class ProviderKeyUpdate(BaseModel):
    key_label: str | None = Field(default=None, min_length=1)
    provider_hint: str | None = None
    base_url: str | None = Field(default=None, min_length=1)
    api_key: str | None = Field(default=None, min_length=1)
    model_name: str | None = Field(default=None, min_length=1)


class ProviderKeyRead(BaseModel):
    """Provider key as returned by the API. ``api_key`` is always masked."""

    model_config = ConfigDict(from_attributes=False)

    id: str
    key_label: str
    provider_hint: str | None
    base_url: str
    api_key: str
    model_name: str
    created_at: UtcDatetime
    updated_at: UtcDatetime


class ActiveProviderKeySummary(BaseModel):
    """Compact summary of the active provider key for the settings endpoint."""

    id: str
    key_label: str
    provider_hint: str | None
    model_name: str
    api_key: str


class SystemSettingsRead(BaseModel):
    active_provider_key_id: str | None
    active_provider_key: ActiveProviderKeySummary | None = None


class ActiveProviderKeyUpdate(BaseModel):
    provider_key_id: str
