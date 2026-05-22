from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated

from pydantic import PlainSerializer


def _to_utc_iso(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.isoformat()


UtcDatetime = Annotated[
    datetime,
    PlainSerializer(_to_utc_iso, return_type=str, when_used="json-unless-none"),
]
