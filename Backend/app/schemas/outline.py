from __future__ import annotations

from pydantic import BaseModel, ConfigDict

from app.schemas.common import UtcDatetime


class OutlineIngest(BaseModel):
    """Body for ``POST /books/{id}/outline/ingest`` (upsert, no LLM)."""

    raw_text: str | None = None


class OutlinePatch(BaseModel):
    """Body for ``PATCH /books/{id}/outline`` — whitelist is ``raw_text`` only.

    The living-outline edit path (the only thing that mutates an outline
    after ingest). Uses ``exclude_unset`` at the call site so an absent key
    is a no-op rather than a null overwrite.
    """

    raw_text: str | None = None


class BookOutlineRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    book_id: str
    raw_text: str | None
    created_at: UtcDatetime
    updated_at: UtcDatetime
