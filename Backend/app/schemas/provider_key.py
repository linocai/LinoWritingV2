from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import UtcDatetime

# v0.7 M-1: stringly-typed agent_role enum surfaces in three places — the
# provider_key payloads, the per-agent active endpoint path parameter, and
# the factory dispatch. Centralised here so adding an Agent later only
# touches one symbol.
AgentRole = Literal["writer", "extractor", "expander"]
AGENT_ROLES: tuple[AgentRole, ...] = ("writer", "extractor", "expander")


def mask_api_key(api_key: str) -> str:
    """Return the api_key masked as `****xxxx` (last 4 chars).

    v0.8 T-1: the argument is the *plaintext* API token, never the Fernet
    ciphertext stored in the database. Callers in ``app.routers.provider_keys``
    decrypt via ``decrypt_api_key`` before invoking this helper. Masking the
    ciphertext tail would expose nothing useful and break the "last 4 of my
    key" UX contract the frontend relies on.

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
    # v0.7 M-1: None = generic key (fallback target for any agent that has
    # no per-agent active set). Otherwise constrains the agents this key
    # may be activated for via PUT /settings/active_key/{agent_role}.
    agent_role: AgentRole | None = None


class ProviderKeyUpdate(BaseModel):
    key_label: str | None = Field(default=None, min_length=1)
    provider_hint: str | None = None
    base_url: str | None = Field(default=None, min_length=1)
    api_key: str | None = Field(default=None, min_length=1)
    model_name: str | None = Field(default=None, min_length=1)
    # v0.7 M-1: PATCH semantics — only overridden when explicitly present
    # in the request body (``exclude_unset``); to clear an existing role
    # back to generic, send ``"agent_role": null``.
    agent_role: AgentRole | None = None


class ProviderKeyRead(BaseModel):
    """Provider key as returned by the API. ``api_key`` is always masked."""

    model_config = ConfigDict(from_attributes=False)

    id: str
    key_label: str
    provider_hint: str | None
    base_url: str
    api_key: str
    model_name: str
    agent_role: AgentRole | None
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


class ActiveAgentKeyRead(BaseModel):
    """Flat shape for the per-Agent active key endpoint (§5.M).

    Mirrors :class:`SystemSettingsRead` but tags the response with the
    ``agent_role`` it represents, so the frontend can render one row per
    Agent without re-issuing GETs to figure out which one it asked about.
    """

    agent_role: AgentRole
    active_provider_key_id: str | None
    key_label: str | None = None
    provider_hint: str | None = None
    model_name: str | None = None
    api_key_mask: str | None = None


class ActiveAgentKeyUpdate(BaseModel):
    """Body for ``PUT /settings/active_key/{agent_role}``.

    A ``provider_key_id`` of ``None`` is the explicit way to clear the
    per-agent pointer back to "fall back to generic" — distinct from never
    having set it. Idempotent: re-PUTting the same id is a no-op.
    """

    provider_key_id: str | None = None
