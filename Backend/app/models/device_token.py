from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class DeviceToken(Base):
    """v0.9 W-1 (§5.W.3) — per-device authentication token.

    Replaces the v0.7 / v0.8 single ``API_TOKEN`` model with one row per
    paired device (macOS / iPhone / iPad), each carrying its own Fernet-
    encrypted token. ``app.auth.require_bearer_token`` walks unrevoked
    rows looking for a matching decrypt; revocation flips ``revoked_at``
    on this row rather than deleting it so an admin can still see what
    was pulled and when.

    The plaintext token is generated server-side at pair-confirm time
    (``secrets.token_hex(32)`` → 32 random bytes → 64 hex chars), shown
    to the client exactly once, and persisted only as Fernet ciphertext.
    Reusing :func:`app.services.encryption.encrypt_api_key` (the
    provider-keys helper) is intentional — same KEK, same key-rotation
    posture, no second crypto surface to keep clean.
    """

    __tablename__ = "device_tokens"

    id: Mapped[str] = mapped_column(
        String(36), primary_key=True, default=lambda: str(uuid.uuid4())
    )
    device_name: Mapped[str] = mapped_column(Text, nullable=False)
    # Fernet ciphertext of the device's bearer token. NEVER store plaintext.
    token_ciphertext: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
    # Updated by ``require_bearer_token`` on each successful auth so the
    # device management UI can show "last used 5 minutes ago".
    last_used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # Set when the user clicks "revoke" in Settings → 设备管理. Once set,
    # the row is permanently inert; we keep it for audit, not deleted.
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
