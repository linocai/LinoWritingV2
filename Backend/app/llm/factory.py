"""LLM client factory.

Builds a per-request :class:`OpenAICompatibleClient` from the currently-active
:class:`ProviderKey` row. There is no startup singleton — every request that
needs an LLM reads ``system_settings.active_provider_key_id`` and constructs
a client on the fly. This makes hot-swapping the active key (via the
``/api/v1/settings/active_provider_key`` endpoint) take effect immediately
without restarting the server.
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from app.errors import upstream
from app.llm.base import LLMClient
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings


def load_active_provider_key(db: Session) -> ProviderKey | None:
    """Return the currently-active :class:`ProviderKey`, or ``None`` if unset.

    ``system_settings`` may not have a row yet (fresh install) or its
    ``active_provider_key_id`` may be ``NULL`` or point at a deleted key —
    all three cases collapse to ``None`` here. Callers decide how to react.
    """

    settings_row = db.get(SystemSettings, 1)
    if settings_row is None:
        return None
    active_id = settings_row.active_provider_key_id
    if active_id is None:
        return None
    return db.get(ProviderKey, active_id)


def build_llm_client(db: Session) -> LLMClient:
    """Build an :class:`LLMClient` for the active provider key.

    Raises an ``upstream`` :class:`AppError` with kind ``upstream`` and
    message ``no_active_llm_key`` if no provider key is currently active.
    Routers should let the error propagate so the global handler renders
    a standard error envelope (502).
    """

    active_key = load_active_provider_key(db)
    if active_key is None:
        raise upstream("no_active_llm_key", retryable=False)
    return OpenAICompatibleClient(active_key)
