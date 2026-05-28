from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.common import utc_now


class PairCode(Base):
    """v0.9 W-1 (§5.W.3) — short-lived 6-digit pairing code.

    Created by ``POST /api/v1/auth/pair_initiate`` (the already-paired
    macOS calls this) and consumed once by ``POST /api/v1/auth/pair_confirm``
    (the new device calls this; pair_confirm is the only Bearer-less
    endpoint).

    The code itself is a zero-padded 0..999999 random integer rendered as
    a 6-char string. 6 digits is intentionally short for the author to
    re-type from the QR / from macOS to iPhone; the brute-force surface
    is controlled by:

    1. 10-minute ``expires_at`` TTL.
    2. ``consumed_at`` makes every code single-shot.
    3. ``/auth/pair_confirm`` is rate-limited to 5/minute per IP at the
       middleware layer (see §5.W.4).

    With those three together the realistic attack surface on a 10-minute
    window is ~50 attempts vs 1,000,000 codes — see §5.W.7 risk analysis.

    Cleanup of expired/consumed rows: §5.W proposes a periodic
    ``DELETE FROM pair_codes WHERE expires_at < now()`` cron, but v0.9
    W-1 only requires the runtime semantics; rows pile up at single-digit
    rate per pairing event and are harmless until manual cleanup or a
    later cron skill lands.
    """

    __tablename__ = "pair_codes"

    code: Mapped[str] = mapped_column(Text, primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
    # expires_at is computed server-side at insert (= created_at + 10 min)
    # rather than stored as a TTL int, so a clock skew between insert and
    # validate doesn't shift the window mid-flight.
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    # Set by pair_confirm on success → code becomes a no-op for any later
    # pair_confirm attempt with the same code (replay defence).
    consumed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # Captured at pair_confirm time so audit logs can join code → device.
    device_name: Mapped[str | None] = mapped_column(Text, nullable=True)
