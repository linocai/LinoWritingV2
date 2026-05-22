from __future__ import annotations

from collections.abc import Iterator
from typing import Any, Protocol

from fastapi import Request


class LLMClient(Protocol):
    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        ...

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        ...

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[str]:
        ...


def get_llm_client(request: Request) -> LLMClient:
    return request.app.state.llm_client
