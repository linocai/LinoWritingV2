"""Tests for v0.8 T-1: ProviderKey api_key Fernet encryption (§5.T).

These tests pin the four contracts the encryption layer must satisfy:

1. Round-trip via the public helpers (encrypt → store → re-read → decrypt
   matches the original plaintext, with a Fernet-looking value on disk).
2. Legacy plaintext rows still decrypt cleanly via the dual-read fallback,
   so a pre-migration row written by an older deployment doesn't break the
   first LLM call after upgrade.
3. ``Settings`` fails fast at construction when ``KEK_SECRET`` is invalid —
   the worst outcome we want to avoid is a healthy-looking startup followed
   by an ``InvalidToken`` 500 on the first LLM call.
4. The public POST /provider_keys endpoint persists ciphertext (not the
   plaintext the caller sent), and the mask helper produces the plaintext
   tail (not the ciphertext tail) — these two together are the wire-level
   contract the iOS frontend depends on.
"""
from __future__ import annotations

import os

import pytest
from cryptography.fernet import Fernet
from pydantic import ValidationError
from sqlalchemy import text

from app.config import Settings
from app.models.provider_key import ProviderKey
from app.services.encryption import (
    decrypt_api_key,
    encrypt_api_key,
    is_fernet_ciphertext,
)
from app.schemas.provider_key import mask_api_key
from tests.conftest import TEST_KEK_SECRET


def test_fernet_round_trip() -> None:
    """encrypt → store → re-read → decrypt matches the original plaintext.

    Also asserts the on-the-wire shape: ciphertext is recognisable via
    ``is_fernet_ciphertext`` and is strictly different from the input. The
    latter is what makes ``grep -r 'sk-' /var/lib/postgres`` a no-op
    post-migration on a real deployment.
    """
    plaintext = "sk-roundtrip-secret-XYZ9"
    ciphertext = encrypt_api_key(plaintext)
    assert ciphertext != plaintext
    assert is_fernet_ciphertext(ciphertext)
    assert decrypt_api_key(ciphertext) == plaintext


def test_legacy_plaintext_read_fallback(db_session) -> None:
    """A row inserted before the data migration (still plaintext) must read
    back cleanly through ``decrypt_api_key`` — InvalidToken triggers the
    v0.8 dual-read fallback, returning the value unchanged.

    The flow is: insert a plaintext row through raw SQL (bypassing the
    router which would have encrypted), then check that the LLM client
    constructor path's helper returns the original token. v0.9 will remove
    this fallback; this test will become a "raises InvalidToken" test then.
    """
    legacy_row = ProviderKey(
        key_label="pre-v0.8 row",
        provider_hint="openai",
        base_url="https://api.openai.com/v1",
        api_key="sk-legacy-PLAINTEXT-1234",  # raw plaintext, no encrypt
        model_name="gpt-4o",
    )
    db_session.add(legacy_row)
    db_session.commit()

    fetched = db_session.get(ProviderKey, legacy_row.id)
    assert fetched is not None
    assert fetched.api_key == "sk-legacy-PLAINTEXT-1234"  # storage unchanged
    # Read-side dual: decrypt_api_key gracefully returns the plaintext.
    assert decrypt_api_key(fetched.api_key) == "sk-legacy-PLAINTEXT-1234"
    # And the helper correctly identifies it as NOT Fernet-shaped, which
    # is what the data migration uses to decide "encrypt this row".
    assert is_fernet_ciphertext(fetched.api_key) is False


def test_kek_invalid_fails_fast() -> None:
    """Settings construction with an invalid KEK must raise ValidationError.

    Two failure modes are interesting:
    1. Length looks right (44 chars) but base64 decoding yields the wrong
       byte count → Fernet rejects.
    2. Length is wrong → the Field(min_length=44, max_length=44) catches.
    Both surface as ValidationError, so the process exits with code 1 at
    startup rather than running healthy until the first LLM call.
    """
    # Case 1: 44 chars, valid base64 alphabet, but decodes to the wrong byte
    # count (``'A' * 44`` base64-decodes to 33 bytes, not 32). Pydantic's
    # length check passes; the Fernet constructor inside the field validator
    # is what must reject this.
    with pytest.raises(ValidationError):
        Settings(
            database_url="sqlite+pysqlite://",
            kek_secret="A" * 44,
        )

    # Case 2: too short — Field(min_length=44) catches before the validator.
    with pytest.raises(ValidationError):
        Settings(
            database_url="sqlite+pysqlite://",
            kek_secret="short",
        )

    # Case 3: non-base64 characters but right length — Fernet decoder fails.
    with pytest.raises(ValidationError):
        Settings(
            database_url="sqlite+pysqlite://",
            kek_secret="!" * 44,
        )


def test_create_provider_key_stores_ciphertext(client, auth_headers, db_session) -> None:
    """POST /provider_keys must persist ciphertext, never plaintext.

    Round-trips through the real router so this catches any future
    regression where someone forgets to encrypt on the create / patch path.
    Re-reads the row via raw SQL on a fresh session to bypass any
    decrypt-in-memory shenanigans and look at what's literally on disk.
    """
    response = client.post(
        "/api/v1/provider_keys",
        headers=auth_headers,
        json={
            "key_label": "encrypt-test",
            "provider_hint": "openai",
            "base_url": "https://api.openai.com/v1",
            "api_key": "sk-plain-on-the-wire-MINE",
            "model_name": "gpt-4o",
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    # Wire returns mask (last 4 of *plaintext*), never plaintext itself.
    assert body["api_key"] == "****MINE"
    key_id = body["id"]

    # Raw read straight out of the DB — bypass ORM hydration paths that
    # might tempt a future refactor to decrypt-on-load.
    stored = db_session.execute(
        text("SELECT api_key FROM provider_keys WHERE id = :id"),
        {"id": key_id},
    ).scalar_one()
    assert stored != "sk-plain-on-the-wire-MINE", (
        "BUG: plaintext API key was persisted to disk — encryption hook is broken"
    )
    assert is_fernet_ciphertext(stored), (
        f"On-disk api_key should be Fernet ciphertext, got: {stored!r}"
    )
    # And the round-trip from on-disk back to plaintext works.
    assert decrypt_api_key(stored) == "sk-plain-on-the-wire-MINE"


def test_mask_api_key_works_on_plaintext() -> None:
    """``mask_api_key`` takes plaintext and returns ``****`` + last 4 chars.

    Locks the contract documented in the schema layer: callers MUST decrypt
    before masking. Masking the ciphertext would still produce a string
    starting with ``****`` but the tail would be the base64 noise tail of
    the Fernet token, not the last 4 of the user's key — which silently
    breaks the iOS "this is your key from xAI" UX.
    """
    assert mask_api_key("sk-test-abcd-WXYZ") == "****WXYZ"
    assert mask_api_key("xy") == "****xy"
    assert mask_api_key("") == "****"


def test_patch_provider_key_re_encrypts_on_rotation(client, auth_headers, db_session) -> None:
    """Rotating the api_key via PATCH must also persist ciphertext.

    Same logic as create but on the update path — the schema layer for
    ``ProviderKeyUpdate`` has the api_key column as optional, so the encrypt
    branch is conditional on ``"api_key" in updates``. This test exercises
    that branch.
    """
    created = client.post(
        "/api/v1/provider_keys",
        headers=auth_headers,
        json={
            "key_label": "rotate-test",
            "provider_hint": "openai",
            "base_url": "https://api.openai.com/v1",
            "api_key": "sk-original-OLD1",
            "model_name": "gpt-4o",
        },
    ).json()
    key_id = created["id"]

    response = client.patch(
        f"/api/v1/provider_keys/{key_id}",
        headers=auth_headers,
        json={"api_key": "sk-rotated-NEW2"},
    )
    assert response.status_code == 200
    assert response.json()["api_key"] == "****NEW2"

    stored = db_session.execute(
        text("SELECT api_key FROM provider_keys WHERE id = :id"),
        {"id": key_id},
    ).scalar_one()
    assert is_fernet_ciphertext(stored)
    assert decrypt_api_key(stored) == "sk-rotated-NEW2"


def test_is_fernet_ciphertext_rejects_obvious_plaintext() -> None:
    """The migration's idempotency guard must not mistake plaintext for
    ciphertext — otherwise pre-v0.8 rows would be skipped forever.

    Each of these is a realistic plaintext API token shape and MUST be
    classified as "needs encryption" by the predicate.
    """
    assert is_fernet_ciphertext("sk-abc123") is False
    assert is_fernet_ciphertext("xai-1234567890abcdef") is False
    assert is_fernet_ciphertext("sk-ant-something_long_ABCDEFGH123456") is False
    assert is_fernet_ciphertext("") is False
    # And it must accept actual Fernet output.
    real = Fernet(TEST_KEK_SECRET.encode()).encrypt(b"hello").decode()
    assert is_fernet_ciphertext(real) is True
