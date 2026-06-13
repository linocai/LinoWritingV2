"""v0.9 W-1 (§5.W.4) — Bearer-token authentication via per-device tokens.

A request authenticates by presenting a Bearer token that matches an
unrevoked ``device_tokens`` row: every active row is Fernet-decrypted and
compared in constant time. On match, ``last_used_at`` is updated for the
device-management UI.

v1.0.0 (EE Phase 6 / D6): the v0.8 static ``api_token`` env-var fallback
has been **removed**. Device pairing (v0.9 W) is the sole credential path;
all real clients have re-paired, so the compatibility branch no longer
guards anything. ``Settings.api_token`` is gone with it (§5.W.2 drop window).

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

from app.db import get_db
from app.errors import unauthorized
from app.models.common import utc_now
from app.models.device_token import DeviceToken
from app.services.encryption import decrypt_api_key

bearer_scheme = HTTPBearer(auto_error=False)


def require_bearer_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
) -> None:
    """Reject the request with 401 unless the Bearer token matches an
    unrevoked ``device_tokens`` row.

    Side effect on success: the matched row's ``last_used_at`` is updated
    and the change is committed.

    The presented token is compared with ``hmac.compare_digest`` to make
    the timing channel uninteresting; the per-row Fernet decrypt itself
    is constant-time-enough for our threat model (single-user system).
    """
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized()
    token = credentials.credentials

    # Device token. Fetch all active rows up-front so we can iterate
    # without holding a cursor open while we issue an UPDATE on a match.
    # N is single-digit in practice (see module docstring).
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

    raise unauthorized()
