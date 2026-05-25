from __future__ import annotations

from collections.abc import Iterator
from threading import Event
from typing import Any, Protocol

from fastapi import Depends
from sqlalchemy.orm import Session

from app.db import get_db


class LLMClient(Protocol):
    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        ...

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        ...

    def complete_stream(
        self,
        *,
        system: str,
        user: str,
        cancel_event: Event | None = None,
        **kwargs: Any,
    ) -> Iterator[str]:
        """Stream LLM tokens.

        If ``cancel_event`` is provided, implementations MUST check it
        regularly during the stream and stop as soon as it is set. This is
        what closes the LLM upstream socket on client-disconnect (e.g. the
        user pressed Cancel) so the provider stops generating tokens and
        we stop being billed for them. See §5.P.1 D.
        """
        ...


def get_llm_client(db: Session = Depends(get_db)) -> LLMClient:
    """FastAPI dependency returning a per-request LLM client.

    Reads the active generic :class:`ProviderKey` from the database and
    constructs an :class:`OpenAICompatibleClient`. Raises
    ``upstream("no_active_llm_key")`` if no key is configured. Test code
    replaces this with a stub via
    ``app.dependency_overrides[get_llm_client]``.

    This is the v0.6-style "generic / global active" entrypoint. v0.7 M-1
    adds per-Agent variants below; routers should prefer those, but this
    one remains valid (e.g. for endpoints that don't belong to any one
    Agent, and as a backstop fallback target via the factory chain).
    """

    # Imported lazily to avoid circular imports between base/factory.
    from app.llm.factory import build_llm_client

    return build_llm_client(db)


# ----- Per-Agent LLM client dependencies (v0.7 M-1, §5.M) -----
#
# Each Agent-specific endpoint should declare the matching dependency so
# the factory routes to the per-Agent ``ProviderKey`` configured by the
# user. They each fall back to the generic active key when no per-Agent
# override is set, so v0.6 deployments behave identically (§5.M.3).
#
# Tests override these individually:
#   ``app.dependency_overrides[get_writer_llm_client] = lambda: MockLLM()``
# Tests that don't care about per-Agent routing can keep overriding only
# ``get_llm_client`` — the factory chain still resolves via the generic
# key in that case.


def get_writer_llm_client(db: Session = Depends(get_db)) -> LLMClient:
    """Per-request LLM client for the Writer agent (§5.M)."""
    from app.llm.factory import build_llm_client

    return build_llm_client(db, agent_role="writer")


def get_extractor_llm_client(db: Session = Depends(get_db)) -> LLMClient:
    """Per-request LLM client for the Extractor agent (§5.M)."""
    from app.llm.factory import build_llm_client

    return build_llm_client(db, agent_role="extractor")


def get_expander_llm_client(db: Session = Depends(get_db)) -> LLMClient:
    """Per-request LLM client for the PromptExpander agent (§5.M)."""
    from app.llm.factory import build_llm_client

    return build_llm_client(db, agent_role="expander")
