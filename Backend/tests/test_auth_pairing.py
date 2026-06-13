"""v0.9 W-1 (§5.W.8) — device pairing endpoint tests.

Coverage:
- pair_initiate happy path + auth required
- pair_confirm valid / wrong / consumed / expired / malformed
- require_bearer_token accepts a paired device token (sole path; v1.0.0
  EE Phase 6 removed the static api_token fallback)
- revoke flow (revoked rejected, 404 on missing, 204 on success)
- list devices excludes ciphertext, ordered newest-first
- pair_confirm rate limit (5/min/IP via middleware)
- last_used_at updates on auth
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.models.device_token import DeviceToken
from app.models.pair_code import PairCode


# --- helpers ----------------------------------------------------------------


def _initiate(client, auth_headers):
    response = client.post("/api/v1/auth/pair_initiate", headers=auth_headers)
    assert response.status_code == 201, response.text
    return response.json()


def _confirm(client, code: str, device_name: str = "linotsai's iPhone"):
    return client.post(
        "/api/v1/auth/pair_confirm",
        json={"code": code, "device_name": device_name},
    )


def _pair_new_device(client, auth_headers, device_name: str = "iPhone"):
    """Run the full initiate+confirm round-trip and return the issued token."""
    code = _initiate(client, auth_headers)["code"]
    resp = _confirm(client, code, device_name=device_name)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    return body["device_id"], body["token"]


# --- pair_initiate ----------------------------------------------------------


def test_pair_initiate_returns_six_digit_code(client, auth_headers):
    body = _initiate(client, auth_headers)
    assert "code" in body
    assert "expires_at" in body
    assert len(body["code"]) == 6
    assert body["code"].isdigit()
    # expires_at must parse and sit ~10 minutes ahead. Allow a generous
    # 30-second slack on each side for slow CI.
    expires = datetime.fromisoformat(body["expires_at"])
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    delta = (expires - now).total_seconds()
    assert 9 * 60 + 30 <= delta <= 10 * 60 + 30, (
        f"expires_at delta = {delta}s, expected ~600s"
    )


def test_pair_initiate_requires_bearer_token(client):
    response = client.post("/api/v1/auth/pair_initiate")
    assert response.status_code == 401
    assert response.json()["error"]["kind"] == "unauthorized"


# --- pair_confirm -----------------------------------------------------------


def test_pair_confirm_valid_code_returns_token_and_device_id(
    client, auth_headers, db_session
):
    code = _initiate(client, auth_headers)["code"]
    resp = _confirm(client, code, device_name="linotsai's iPhone")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # device_id is a UUID string (36 chars with hyphens).
    assert len(body["device_id"]) == 36
    # 32-byte hex token → exactly 64 chars.
    assert len(body["token"]) == 64
    assert all(c in "0123456789abcdef" for c in body["token"])

    # The new device must NOT be visible via direct ciphertext leak in
    # the DB walk we expose via /devices — we verify that further below
    # in test_list_devices_returns_items_no_token_ciphertext.


def test_pair_confirm_wrong_code(client, auth_headers):
    # Initiate first so there's *some* row in the table, otherwise we'd
    # be testing the trivial "empty table" path.
    _initiate(client, auth_headers)
    resp = _confirm(client, "999999")
    assert resp.status_code == 401
    body = resp.json()
    assert body["error"]["kind"] == "unauthorized"
    # Chinese error message — §5.N envelope contract.
    assert "配对码" in body["error"]["message"]


def test_pair_confirm_consumed_code(client, auth_headers):
    code = _initiate(client, auth_headers)["code"]
    # First use succeeds.
    ok = _confirm(client, code)
    assert ok.status_code == 200
    # Second use of the same code must fail.
    again = _confirm(client, code)
    assert again.status_code == 401
    assert "配对码" in again.json()["error"]["message"]


def test_pair_confirm_expired_code(client, auth_headers, db_session):
    # Mint a fresh code via the real endpoint, then mutate ``expires_at``
    # directly on the row to simulate the 10-minute window having passed.
    code = _initiate(client, auth_headers)["code"]
    row = db_session.get(PairCode, code)
    assert row is not None
    row.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    db_session.commit()

    resp = _confirm(client, code)
    assert resp.status_code == 401
    assert "配对码" in resp.json()["error"]["message"]


@pytest.mark.parametrize(
    "bad_code",
    [
        "12345",      # too short
        "1234567",    # too long
        "12345a",     # contains letter
        "",           # empty
        "12 456",     # contains space
    ],
)
def test_pair_confirm_invalid_format_rejected_by_schema(
    client, auth_headers, bad_code
):
    _initiate(client, auth_headers)
    resp = client.post(
        "/api/v1/auth/pair_confirm",
        json={"code": bad_code, "device_name": "x"},
    )
    # FastAPI / Pydantic validation → 422 wrapped by our standard envelope.
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["kind"] == "validation"


# --- require_bearer_token (device token is the sole credential path) --------


def test_require_bearer_token_accepts_device_token(client, auth_headers):
    _, token = _pair_new_device(client, auth_headers)
    # Use a freshly-paired device token (distinct from the fixture's token).
    resp = client.get(
        "/api/v1/health",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text


def test_require_bearer_token_rejects_unpaired_token(client, auth_headers):
    # v1.0.0 EE Phase 6 (D6): the static api_token fallback is gone. A token
    # that matches no unrevoked device_tokens row must be rejected even with
    # other devices paired on file (forcing the decrypt walk to run and miss).
    _pair_new_device(client, auth_headers)
    resp = client.get(
        "/api/v1/health",
        headers={"Authorization": "Bearer not-a-paired-device-token"},
    )
    assert resp.status_code == 401
    assert resp.json()["error"]["kind"] == "unauthorized"


def test_device_token_updates_last_used_at(client, auth_headers, db_session):
    device_id, token = _pair_new_device(client, auth_headers)
    # Sanity: last_used_at starts NULL right after pairing.
    row = db_session.get(DeviceToken, device_id)
    assert row is not None
    assert row.last_used_at is None

    # Drive a few auth'd requests with the device token.
    for _ in range(3):
        resp = client.get(
            "/api/v1/health",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 200

    # Re-read from DB — last_used_at should now be set. We refresh
    # because the session may still hold the stale value otherwise.
    db_session.expire_all()
    row = db_session.get(DeviceToken, device_id)
    assert row.last_used_at is not None


# --- revoke -----------------------------------------------------------------


def test_revoked_device_token_rejected(client, auth_headers):
    device_id, token = _pair_new_device(client, auth_headers)
    # Sanity: works before revoke.
    pre = client.get(
        "/api/v1/health",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert pre.status_code == 200

    revoke = client.delete(
        f"/api/v1/auth/devices/{device_id}",
        headers=auth_headers,
    )
    assert revoke.status_code == 204

    # After revoke, the same token must be rejected even though it would
    # still decrypt cleanly.
    post = client.get(
        "/api/v1/health",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert post.status_code == 401


def test_revoke_nonexistent_device_404(client, auth_headers):
    resp = client.delete(
        "/api/v1/auth/devices/00000000-0000-0000-0000-000000000000",
        headers=auth_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["kind"] == "not_found"


def test_revoke_idempotent(client, auth_headers):
    device_id, _token = _pair_new_device(client, auth_headers)
    first = client.delete(
        f"/api/v1/auth/devices/{device_id}",
        headers=auth_headers,
    )
    assert first.status_code == 204
    second = client.delete(
        f"/api/v1/auth/devices/{device_id}",
        headers=auth_headers,
    )
    # Second call is allowed but no-ops; still 204 not 404.
    assert second.status_code == 204


# --- list devices -----------------------------------------------------------


def test_list_devices_returns_items_no_token_ciphertext(client, auth_headers):
    _pair_new_device(client, auth_headers, device_name="linotsai's iPhone")
    _pair_new_device(client, auth_headers, device_name="linotsai's iPad")

    resp = client.get("/api/v1/auth/devices", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert "items" in body
    names = [row["device_name"] for row in body["items"]]
    assert "linotsai's iPhone" in names
    assert "linotsai's iPad" in names
    # Ordering: newest first (iPad was paired second).
    assert body["items"][0]["device_name"] == "linotsai's iPad"

    # Hard contract: no cipher material in the response.
    for row in body["items"]:
        assert "token_ciphertext" not in row
        assert "token" not in row
        # And the visible shape is exactly what the schema documents.
        assert set(row.keys()) == {
            "device_id",
            "device_name",
            "created_at",
            "last_used_at",
        }


def test_list_devices_requires_bearer_token(client):
    resp = client.get("/api/v1/auth/devices")
    assert resp.status_code == 401


# --- pair_confirm rate limit ------------------------------------------------


def test_pair_confirm_rate_limit_5_per_minute_per_ip(client, auth_headers):
    """The 6th anonymous pair_confirm in a minute must hit 429 even when
    every previous attempt was 401 (wrong code).

    We deliberately use wrong codes — the limiter sits *outside* the
    router and consumes a slot regardless of inner result.
    """
    # Make sure there's at least one valid code row so the wrong-code
    # path exercises the same DB walk as production. Not strictly
    # needed for rate-limit behaviour but keeps the test realistic.
    _initiate(client, auth_headers)
    for index in range(5):
        resp = _confirm(client, "999999")
        assert resp.status_code == 401, (
            f"call {index} expected 401, got {resp.status_code}"
        )
    # 6th call exceeds 5/min/IP → 429 envelope with Retry-After.
    blocked = _confirm(client, "999999")
    assert blocked.status_code == 429
    assert blocked.headers.get("Retry-After") == "60"
    body = blocked.json()
    assert body["error"]["kind"] == "rate_limited"
    assert body["error"]["details"]["retry_after_seconds"] == 60


def test_pair_initiate_not_under_5_per_minute_limit(client, auth_headers):
    """Sanity check on the rate-limit scoping: only pair_confirm gets the
    5/min cap. pair_initiate sits on the normal 600/min bucket so the
    user can re-issue codes liberally (e.g. they lost the QR window).
    """
    # 6 inits must all succeed — well under the 600/min default.
    for index in range(6):
        resp = client.post("/api/v1/auth/pair_initiate", headers=auth_headers)
        assert resp.status_code == 201, (
            f"call {index}: expected 201, got {resp.status_code}"
        )


# --- DB-level integrity sanity ----------------------------------------------


def test_pair_confirm_persists_encrypted_token(client, auth_headers, db_session):
    """The persisted row must hold Fernet ciphertext (``gAAAAA...``)
    rather than the plaintext token the API returned. This is the
    single most important on-disk invariant of W-1: a DB dump must not
    reveal any device's bearer credential.
    """
    _, plaintext = _pair_new_device(client, auth_headers)
    rows = db_session.execute(select(DeviceToken)).scalars().all()
    # v1.0.0 EE Phase 6: ``auth_headers`` itself mints a device_tokens row,
    # so the table holds that fixture row plus the one paired above. Locate
    # the paired device's row by its ciphertext (no row stores plaintext) and
    # assert the on-disk invariant on it specifically.
    stored_values = [row.token_ciphertext for row in rows]
    # The plaintext token must not appear verbatim in ANY stored ciphertext.
    for stored in stored_values:
        assert plaintext not in stored
        # Fernet output is url-safe base64 starting with ``gAAAAA``.
        assert stored.startswith("gAAAAA"), (
            f"token_ciphertext does not look like a Fernet token: {stored[:16]}..."
        )
