from __future__ import annotations

from pydantic import BaseModel, Field

from app.schemas.common import UtcDatetime


class PairInitiateResponse(BaseModel):
    """Body of ``POST /api/v1/auth/pair_initiate``.

    The 6-digit code is generated server-side as a random 0-999999
    rendered zero-padded to width 6. ``expires_at`` is ISO-8601 UTC and
    the frontend draws a countdown clock off of it.
    """

    code: str = Field(min_length=6, max_length=6)
    expires_at: UtcDatetime


class PairConfirmRequest(BaseModel):
    """Body of ``POST /api/v1/auth/pair_confirm`` (the only Bearer-less
    endpoint in the API).

    ``code`` is constrained to exactly 6 ASCII digits at the schema layer
    so any malformed input gets a 422 from FastAPI's validation pass
    before the router (and therefore before the DB lookup that would
    otherwise be a free 401 oracle).

    ``device_name`` is author-supplied (or defaulted to ``UIDevice.current
    .name`` / ``Host.current().localizedName`` on the client) and shown in
    the macOS Settings → 设备管理 list — so we cap it to a reasonable
    length to keep that list legible without truncation.
    """

    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    device_name: str = Field(min_length=1, max_length=80)


class PairConfirmResponse(BaseModel):
    """Body of ``POST /api/v1/auth/pair_confirm`` on success.

    ``token`` is the plaintext device token (64-char hex from
    ``secrets.token_hex(32)``) and is returned EXACTLY ONCE — the frontend
    must persist it to Keychain immediately. The DB only ever sees the
    Fernet ciphertext.
    """

    device_id: str
    token: str


class DeviceRead(BaseModel):
    """One row in ``GET /api/v1/auth/devices``.

    Deliberately NEVER includes ``token_ciphertext`` (the wire payload
    must stay free of any cipher material that an attacker who later
    obtains the KEK could decrypt offline).
    """

    device_id: str
    device_name: str
    created_at: UtcDatetime
    last_used_at: UtcDatetime | None = None


class DeviceListResponse(BaseModel):
    items: list[DeviceRead]
