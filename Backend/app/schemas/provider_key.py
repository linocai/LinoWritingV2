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


class SystemSettingsRead(BaseModel):
    """Flat shape of the active-provider-key endpoint response.

    Plan §5.E.4 explicitly specifies "id + 摘要(provider_hint / key_label /
    model_name / 末 4 位)" — flat, not nested. The previous nested shape
    (active_provider_key: ProviderKeyRead | None) made the frontend's
    flat Codable model fail to decode anything but the id.
    """

    active_provider_key_id: str | None
    key_label: str | None = None
    provider_hint: str | None = None
    model_name: str | None = None
    api_key_mask: str | None = None  # "****xxxx" or None when no active key


class ActiveProviderKeyUpdate(BaseModel):
    provider_key_id: str
