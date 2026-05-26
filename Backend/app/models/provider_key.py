from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class ProviderKey(Base):
    __tablename__ = "provider_keys"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    key_label: Mapped[str] = mapped_column(Text, nullable=False)
    provider_hint: Mapped[str | None] = mapped_column(Text)
    base_url: Mapped[str] = mapped_column(Text, nullable=False)
    # v0.8 T-1 (§5.T): on-disk value is Fernet ciphertext, NOT the plaintext
    # API token. Encrypt via ``app.services.encryption.encrypt_api_key`` on
    # write and ``decrypt_api_key`` on read. The column type stays Text
    # because Fernet output is url-safe base64 ASCII (``gAAAAA...``). The
    # Alembic data migration ``202605260003`` walks any pre-v0.8 plaintext
    # rows and rewrites them encrypted.
    api_key: Mapped[str] = mapped_column(Text, nullable=False)
    model_name: Mapped[str] = mapped_column(Text, nullable=False)
    # v0.7 M-1: optional Agent affinity. NULL = generic (eligible as the
    # global active key for any agent); otherwise one of {'writer',
    # 'extractor', 'expander'}. Routed by ``system_settings.active_*_key_id``
    # via :func:`app.llm.factory.load_active_provider_key_for_agent` with a
    # generic-active fall-back so v0.6 deployments behave unchanged.
    agent_role: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utc_now,
        onupdate=utc_now,
        nullable=False,
    )
