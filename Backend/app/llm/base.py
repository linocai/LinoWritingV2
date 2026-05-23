from __future__ import annotations

from collections.abc import Iterator
from typing import Any, Protocol

from fastapi import Depends
from sqlalchemy.orm import Session

from app.db import get_db


class LLMClient(Protocol):
    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        ...

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        ...

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[str]:
        ...


def get_llm_client(db: Session = Depends(get_db)) -> LLMClient:
    """FastAPI dependency returning a per-request LLM client.

    Reads the active :class:`ProviderKey` from the database and constructs
    an :class:`OpenAICompatibleClient`. Raises ``upstream("no_active_llm_key")``
    if no key is configured. Test code replaces this with a stub via
    ``app.dependency_overrides[get_llm_client]``.
    """

    # Imported lazily to avoid circular imports between base/factory.
    from app.llm.factory import build_llm_client

    return build_llm_client(db)
