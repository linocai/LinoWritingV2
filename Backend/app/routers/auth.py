"""v0.9 W-1 (§5.W.4) — device pairing endpoints.

Four routes mounted under ``/api/v1/auth``:

- ``POST /auth/pair_initiate``   — already-paired device requests a 6-digit
                                   short code. Requires Bearer.
- ``POST /auth/pair_confirm``    — new device exchanges code → token.
                                   **The only Bearer-less endpoint** in the
                                   API; rate-limited to 5/min per IP at the
                                   middleware layer.
- ``GET  /auth/devices``         — list paired devices. Requires Bearer.
- ``DELETE /auth/devices/{id}``  — revoke a device. Requires Bearer.

The router itself is intentionally NOT registered with
``dependencies=[Depends(require_bearer_token)]`` in main.py — instead each
function that needs auth declares ``_auth: None = Depends(require_bearer_token)``
explicitly, which lets ``pair_confirm`` opt out as the single whitelisted
endpoint (§5.W.4).
"""
from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import require_bearer_token
from app.db import get_db
from app.errors import unauthorized
from app.models.common import utc_now
from app.models.device_token import DeviceToken
from app.models.pair_code import PairCode
from app.schemas.auth import (
    DeviceListResponse,
    DeviceRead,
    PairConfirmRequest,
    PairConfirmResponse,
    PairInitiateResponse,
)
from app.services.encryption import encrypt_api_key

router = APIRouter(prefix="/auth", tags=["auth"])


# §5.W.2 decision: 6-digit numeric, 10-minute TTL. Centralised constants
# so anyone reading the router doesn't have to remember the §-reference.
PAIR_CODE_TTL = timedelta(minutes=10)
DEVICE_TOKEN_BYTES = 32  # 32 bytes → 64 hex chars, matching v0.7/v0.8 API_TOKEN shape.


def _generate_pair_code() -> str:
    """Return a fresh 6-digit pairing code as a zero-padded string.

    ``secrets.randbelow`` (not ``random.randint``) so the code is drawn
    from the OS CSPRNG. Width 6 means leading zeros are preserved on the
    wire — the schema layer enforces exactly 6 chars on the confirm side,
    so dropping a leading zero would silently break pair_confirm on every
    code that started with ``0``.
    """
    return f"{secrets.randbelow(1_000_000):06d}"


def _ensure_aware(value: datetime) -> datetime:
    """SQLite via SQLAlchemy returns naive datetimes even from columns
    declared with ``timezone=True``. Postgres returns aware. To keep TTL
    arithmetic correct on both backends, normalise to aware-UTC.
    """
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


@router.post(
    "/pair_initiate",
    response_model=PairInitiateResponse,
    status_code=status.HTTP_201_CREATED,
)
def pair_initiate(
    db: Session = Depends(get_db),
    _auth: None = Depends(require_bearer_token),
) -> PairInitiateResponse:
    """Issue a fresh 6-digit pairing code valid for 10 minutes.

    Multiple ``pair_initiate`` calls from the same device produce
    independent codes (each with its own 10-min TTL) — no de-dup. That
    matches §5.W.7 ("multi-device simultaneous pairing"): the macOS user
    might be onboarding both an iPhone and an iPad and we shouldn't make
    them serialise.

    Collision handling: the 1M code space is sparse enough that random
    collisions are astronomically unlikely in practice, but the PK on
    ``pair_codes.code`` means a duplicate would raise IntegrityError. We
    retry once on collision to avoid surfacing that as a 500 to the user.
    """
    created_at = utc_now()
    expires_at = created_at + PAIR_CODE_TTL
    code = _generate_pair_code()
    # Retry once on PK collision — see docstring. After two consecutive
    # collisions something is seriously wrong (or our entropy source is
    # broken) so we let the IntegrityError bubble to the standard
    # exception handler.
    for _ in range(2):
        existing = db.get(PairCode, code)
        if existing is None:
            break
        code = _generate_pair_code()
    db.add(
        PairCode(
            code=code,
            created_at=created_at,
            expires_at=expires_at,
            consumed_at=None,
            device_name=None,
        )
    )
    db.commit()
    return PairInitiateResponse(code=code, expires_at=expires_at)


@router.post("/pair_confirm", response_model=PairConfirmResponse)
def pair_confirm(
    payload: PairConfirmRequest,
    db: Session = Depends(get_db),
) -> PairConfirmResponse:
    """Exchange a valid pairing code for a fresh device token.

    No Bearer required (the whole point of the endpoint). Validates:
    1. code row exists,
    2. ``consumed_at`` is NULL (replay defence),
    3. ``expires_at`` is in the future (TTL defence).

    On success, all three of these happen in a single transaction:
    - generate a random 32-byte token,
    - insert a ``device_tokens`` row with its Fernet ciphertext,
    - mark the pair_code row consumed.

    The plaintext token is returned exactly once. If the client loses it
    before persisting to Keychain, they must run a fresh pair_initiate.

    Brute-force surface: 1M code space × 10-min TTL × 5/min per IP →
    realistically ~50 attempts per window per IP. Plus a 401 from a
    wrong code returns the same generic Chinese message as a 401 from
    an expired/consumed one so there's no oracle to differentiate
    "code was valid yesterday" from "code was never valid".
    """
    code_row = db.get(PairCode, payload.code)
    if code_row is None:
        # 401 not 404 — deliberate. The endpoint is anonymous and we
        # don't want unauthenticated callers to learn whether a code
        # ever existed; that would convert pair_confirm into a 1M-row
        # existence oracle the rate limiter can't fully prevent.
        raise unauthorized("配对码无效或已过期")

    now = utc_now()

    if code_row.consumed_at is not None:
        raise unauthorized("配对码无效或已过期")

    # See _ensure_aware docstring — SQLite reads come back naive.
    if _ensure_aware(code_row.expires_at) <= now:
        raise unauthorized("配对码无效或已过期")

    # All checks passed → generate token, persist ciphertext, consume code.
    plaintext_token = secrets.token_hex(DEVICE_TOKEN_BYTES)
    ciphertext = encrypt_api_key(plaintext_token)
    device = DeviceToken(
        device_name=payload.device_name,
        token_ciphertext=ciphertext,
        created_at=now,
    )
    db.add(device)
    code_row.consumed_at = now
    code_row.device_name = payload.device_name
    db.commit()
    db.refresh(device)
    return PairConfirmResponse(device_id=device.id, token=plaintext_token)


@router.get("/devices", response_model=DeviceListResponse)
def list_devices(
    db: Session = Depends(get_db),
    _auth: None = Depends(require_bearer_token),
) -> DeviceListResponse:
    """List all paired devices, newest first, capped at 100.

    Revoked devices are included so the user can see their full pairing
    history; the frontend can grey them out. Token ciphertext is
    excluded from the response by the ``DeviceRead`` schema's omission
    of the field — see schemas/auth.py for rationale.
    """
    rows = db.execute(
        select(DeviceToken)
        .order_by(DeviceToken.created_at.desc())
        .limit(100)
    ).scalars().all()
    return DeviceListResponse(
        items=[
            DeviceRead(
                device_id=row.id,
                device_name=row.device_name,
                created_at=row.created_at,
                last_used_at=row.last_used_at,
            )
            for row in rows
        ]
    )


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
def revoke_device(
    device_id: str,
    db: Session = Depends(get_db),
    _auth: None = Depends(require_bearer_token),
) -> Response:
    """Revoke a paired device by setting ``revoked_at = now()``.

    We do NOT delete the row — keeping a permanent audit trail matters
    more than the tiny storage win. A revoked row is permanently inert:
    ``require_bearer_token`` filters revoked rows out of its decrypt
    walk, so a leaked token whose row was revoked yesterday will get
    401'd today even if it's syntactically valid.

    Returns 404 (not 204) for nonexistent ids so the macOS UI can
    distinguish "I revoked it" from "it was already gone".
    """
    device = db.get(DeviceToken, device_id)
    if device is None:
        # We use a vanilla 404 so the operator sees the standard error
        # envelope with kind=not_found; there's nothing user-facing here
        # that needs an i18n template.
        from app.errors import not_found

        raise not_found("Device not found")
    # Idempotent: revoking an already-revoked device just no-ops. This
    # makes the frontend's "click trash, click trash again before the
    # list refreshes" UX safe.
    if device.revoked_at is None:
        device.revoked_at = utc_now()
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
