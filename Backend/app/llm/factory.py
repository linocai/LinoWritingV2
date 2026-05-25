"""LLM client factory.

Builds a per-request :class:`OpenAICompatibleClient` from the currently-active
:class:`ProviderKey` row. There is no startup singleton — every request that
needs an LLM reads ``system_settings`` and constructs a client on the fly.
This makes hot-swapping the active key (via the various
``/api/v1/settings/active_*_key`` endpoints) take effect immediately without
restarting the server.

v0.7 M-1 (§5.M): factory is now per-Agent aware. The resolution chain is:

    1. If ``agent_role`` is given and ``system_settings.active_{role}_key_id``
       points at a row, use that.
    2. Otherwise fall back to the generic ``active_provider_key_id`` row
       (v0.6 behavior — preserved for backward compatibility).
    3. If neither resolves, raise ``upstream("no_active_llm_key")``.

A v0.6 deployment with all three per-Agent pointers NULL therefore behaves
identically to v0.6 (every Agent resolves via step 2). See §5.M.3.
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from app.errors import i18n_upstream
from app.llm.base import LLMClient
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.schemas.provider_key import AgentRole

# Mirror of the router-side mapping. Kept here (instead of imported from
# the router) so app.llm.factory has no router dependency — the factory is
# imported from many places including conftest/test fixtures, and pulling
# in the router module would broaden the import graph for tests.
_AGENT_TO_SETTINGS_COLUMN: dict[str, str] = {
    "writer": "active_writer_key_id",
    "extractor": "active_extractor_key_id",
    "expander": "active_expander_key_id",
}


def load_active_provider_key(db: Session) -> ProviderKey | None:
    """Return the currently-active generic :class:`ProviderKey`, or ``None``.

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


def load_active_provider_key_for_agent(
    db: Session, agent_role: AgentRole | str | None
) -> ProviderKey | None:
    """Resolve the active :class:`ProviderKey` for a specific Agent role.

    The chain is described in the module docstring. ``agent_role=None``
    short-circuits to the generic loader for symmetry with v0.6 callers
    that don't care about per-Agent selection.

    Unknown role strings fall back to the generic loader as well — the
    schema layer should have already rejected them, but if a typo slips
    through we degrade gracefully to v0.6 behavior rather than 500.
    """

    if agent_role is None:
        return load_active_provider_key(db)

    column = _AGENT_TO_SETTINGS_COLUMN.get(agent_role)
    if column is None:
        return load_active_provider_key(db)

    settings_row = db.get(SystemSettings, 1)
    if settings_row is not None:
        per_agent_id: str | None = getattr(settings_row, column)
        if per_agent_id is not None:
            key = db.get(ProviderKey, per_agent_id)
            if key is not None:
                return key
            # Stale FK — fall through to generic rather than 500.
    return load_active_provider_key(db)


def build_llm_client(
    db: Session, agent_role: AgentRole | str | None = None
) -> LLMClient:
    """Build an :class:`LLMClient` for the active provider key.

    When ``agent_role`` is given, the per-Agent override is preferred and
    falls back to the generic active key (v0.6 behavior). When omitted,
    only the generic key is consulted — preserving the v0.6 signature so
    existing callers (and tests) don't have to thread an agent_role they
    don't need.

    Raises an ``upstream`` :class:`AppError` with kind ``upstream`` and
    message ``no_active_llm_key`` if no provider key resolves. Routers
    should let the error propagate so the global handler renders a
    standard error envelope (502).
    """

    active_key = load_active_provider_key_for_agent(db, agent_role)
    if active_key is None:
        # v0.7 §5.N — Chinese template + machine-readable ``code`` in
        # details. Tests that previously asserted ``message ==
        # "no_active_llm_key"`` now switch to asserting
        # ``details["code"] == "no_active_llm_key"`` (see test changes).
        raise i18n_upstream(
            "llm_no_active_key",
            retryable=False,
            details={"code": "no_active_llm_key"},
        )
    return OpenAICompatibleClient(active_key)
