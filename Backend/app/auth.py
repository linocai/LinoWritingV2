"""v0.9 W-1 (§5.W.4) — Bearer-token authentication with two paths.

Two ways a request can authenticate, tried in order:

1. **Per-device token** (the v0.9 primary path). The presented token is
   matched against every unrevoked ``device_tokens`` row by Fernet
   decrypt + constant-time comparison. On match, ``last_used_at`` is
   updated for the device-management UI.

2. **Static ``api_token`` env-var** (v0.8 compatibility path). If no
   device-token row matches, fall back to comparing against
   ``Settings.api_token``. This keeps every existing client (the macOS
   that's already paired with the old env-var, the test suite's
   ``TEST_TOKEN``) working through v0.9.x; the §5.W.2 decision is to
   drop this fallback in v1.0 once all real clients have re-paired.

The decrypt walk is O(N) over device rows. The author's deployment has
single-digit N (a Mac, an iPhone, maybe an iPad), so this is microseconds
on every request — well under any threshold that would justify adding
a hash-side-column to do O(1) lookup. If a future deployment ever scales
to >50 paired devices the right move is to add a token-hash column and
look up by hash first; the model + decryption helpers stay unchanged.
"""
from __future__ import annotations

import hmac

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_db
from app.errors import unauthorized
from app.models.common import utc_now
from app.models.device_token import DeviceToken
from app.services.encryption import decrypt_api_key

bearer_scheme = HTTPBearer(auto_error=False)


def require_bearer_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> None:
    """Reject the request with 401 unless the Bearer token matches one
    of the two accepted credentials (see module docstring).

    Side effect on success: if matched against a ``device_tokens`` row,
    the row's ``last_used_at`` is updated and the change is committed.
    Static-token path commits nothing — it's a pure equality check.

    The presented token is compared with ``hmac.compare_digest`` to make
    the timing channel uninteresting; the per-row Fernet decrypt itself
    is constant-time-enough for our threat model (single-user system).
    """
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized()
    token = credentials.credentials

    # Path 1 — device token.
    # Fetch all active rows up-front so we can iterate without holding a
    # cursor open while we issue an UPDATE on a match. N is single-digit
    # in practice (see module docstring).
    rows = db.execute(
        select(DeviceToken).where(DeviceToken.revoked_at.is_(None))
    ).scalars().all()
    for row in rows:
        try:
            plaintext = decrypt_api_key(row.token_ciphertext)
        except Exception:
            # A corrupted ciphertext (KEK rotation gone wrong, manual
            # DB tampering) should not crash auth for every other
            # device. Skip the bad row; the rest of the walk continues.
            continue
        if hmac.compare_digest(plaintext, token):
            row.last_used_at = utc_now()
            db.commit()
            return

    # Path 2 — static api_token (v0.8 fallback). compare_digest because
    # the env-var token is the literal high-value secret here; we don't
    # want the per-byte comparison to be a timing oracle.
    if hmac.compare_digest(token, settings.api_token):
        return

    raise unauthorized()
