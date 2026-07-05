from __future__ import annotations

from collections.abc import Iterator
from threading import Event
from typing import Any, Literal, NamedTuple, Protocol

from fastapi import Depends
from sqlalchemy.orm import Session

from app.db import get_db


class StreamChunk(NamedTuple):
    """v1.2.0 (HH) P7 — a single typed unit yielded by ``complete_stream``.

    This is the **authoritative** contract change: ``complete_stream`` used
    to yield bare ``str`` tokens; reasoning-capable upstreams (DeepSeek-R1
    style ``reasoning_content`` deltas, etc.) need a way to tell the consumer
    "this text is the model's chain-of-thought, not final prose" so it can
    be surfaced as a transient "thinking…" indicator instead of being
    appended to the chapter draft or counted toward word count.

    ``kind`` is a closed two-value tag rather than a boolean so a future
    third stream-chunk category (should one ever be needed) doesn't require
    flipping a polarity everywhere ``kind == "token"`` is checked today.

    Every consumer of ``complete_stream`` (writer.py's sole caller, plus
    every test's stub LLM) must be updated in lockstep — this is a Protocol
    change, so a stub that still ``yield``s bare strings will type-check
    fine (Python doesn't enforce Protocol shapes at runtime) but blow up
    with an ``AttributeError``/unpacking error the moment production code
    tries `.kind`/`.text` on a plain `str`.
    """
    kind: Literal["token", "thinking"]
    text: str


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
    ) -> Iterator[StreamChunk]:
        """Stream LLM output as typed chunks (v1.2.0 P7 — was ``Iterator[str]``).

        Yields :class:`StreamChunk` — ``kind="token"`` for final-answer
        content (goes into the draft, counted toward word count) and
        ``kind="thinking"`` for chain-of-thought / reasoning deltas (surfaced
        as a transient UI indicator only, never persisted to draft_text).

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
