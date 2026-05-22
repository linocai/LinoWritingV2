from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class AgentResult:
    output: Any
    tokens_in: int | None = None
    tokens_out: int | None = None
