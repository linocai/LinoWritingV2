"""ProviderKey API key encryption (v0.8 T-1, §5.T).

Fernet (AES-128-CBC + HMAC-SHA256) wrapper around the ``provider_keys.api_key``
column. The cleartext API token (e.g. ``sk-...`` / ``xai-...``) is encrypted
with a single Key Encryption Key (KEK) read from the ``KEK_SECRET`` environment
variable, and the base64 ciphertext (``gAAAAA...``) is what lives on disk.

Why Fernet (not raw AES-GCM):
- Standard `cryptography` recipe; opinion-free for callers (the recipe handles
  IV, version byte, MAC, timestamp); aligns with §5.T.2's choice.
- Single-row encrypt/decrypt is well under 0.1ms — perf irrelevant for our
  workload (one decrypt per LLM-bearing request).

Read-side dual (v0.8 only):
``decrypt_api_key`` falls back to returning the input unchanged when Fernet's
``InvalidToken`` fires, so a row inserted before the Alembic data migration ran
(or seeded by code paths the migration missed) still works at read time. This
is a TRANSITIONAL behavior — once we are confident no plaintext rows exist on
any deployment, the fallback is to be removed in v0.9 and ``decrypt_api_key``
will surface ``InvalidToken`` as a hard error.

Migration handshake:
``is_fernet_ciphertext`` is the predicate the data migration uses to decide
"already encrypted? skip. plaintext? encrypt and rewrite". It checks the
Fernet token prefix bytes after url-safe base64 decode rather than re-running
``decrypt_api_key`` so we don't pay (and don't depend on) the KEK to recognize
ciphertext shape.
"""
from __future__ import annotations

import base64
import binascii
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken


@lru_cache(maxsize=1)
def get_cipher() -> Fernet:
    """Return a process-wide :class:`Fernet` instance built from ``KEK_SECRET``.

    Cached because constructing a Fernet does a small amount of key-decoding
    work and we'd otherwise repeat it on every request. The cache is keyed on
    the function (no args) so a KEK rotation requires a process restart —
    intentional: v0.8 explicitly does not implement live rotation (§5.T.5).
    """
    # Local import to keep this module importable from Alembic migrations
    # (which must not pull in app.config because that triggers a Pydantic
    # validation cycle when run before the env is set up).
    from app.config import get_settings

    settings = get_settings()
    return Fernet(settings.kek_secret.encode("ascii"))


def encrypt_api_key(plaintext: str) -> str:
    """Encrypt ``plaintext`` and return the url-safe base64 ciphertext.

    Empty / whitespace-only input is returned unchanged: a blank ``api_key``
    has no secret to protect, and round-tripping it through Fernet would
    surprise the schema-layer ``min_length=1`` validator.
    """
    if not plaintext:
        return plaintext
    cipher = get_cipher()
    token = cipher.encrypt(plaintext.encode("utf-8"))
    return token.decode("ascii")


def decrypt_api_key(value: str) -> str:
    """Decrypt ``value`` to its plaintext form, with a v0.8 legacy fallback.

    Behavior:
    1. Empty input → empty output (symmetric with ``encrypt_api_key``).
    2. Valid Fernet ciphertext → decrypted plaintext.
    3. Anything Fernet rejects (``InvalidToken``) → return the input unchanged.
       This is the TRANSITIONAL pre-migration fallback (§5.T.2 "Read-side
       dual"). It will be removed in v0.9; from then on legacy plaintext rows
       will raise instead of silently passing through.
    """
    if not value:
        return value
    cipher = get_cipher()
    try:
        plaintext = cipher.decrypt(value.encode("ascii"))
    except InvalidToken:
        # v0.8 dual-read compatibility — see module docstring.
        # IMPORTANT: remove this branch in v0.9 along with the Alembic data
        # migration once prod is confirmed fully migrated.
        return value
    return plaintext.decode("utf-8")


def is_fernet_ciphertext(value: str) -> bool:
    """Heuristic: does ``value`` look like a Fernet token?

    A Fernet token is url-safe-base64 of a payload that starts with a version
    byte ``0x80``. We decode and check that first byte — much cheaper than
    actually decrypting (which would require KEK) and tight enough to reject
    plaintext API keys (``sk-...`` / ``xai-...``) by sheer base64 shape.

    Returns False on any decode error so the data migration treats malformed
    values as plaintext (which it will then try to encrypt). That's the safer
    default: re-encrypting a row twice is impossible (we check this predicate
    before encrypt), but skipping a legit plaintext row would leave it on disk
    forever.
    """
    if not value:
        return False
    try:
        raw = base64.urlsafe_b64decode(value.encode("ascii"))
    except (binascii.Error, ValueError, UnicodeEncodeError):
        return False
    # Fernet v1 tokens start with 0x80 followed by an 8-byte timestamp and a
    # 16-byte IV → minimum payload length is 1 + 8 + 16 + 32 (HMAC) = 57. The
    # MAC is variable in spec but in practice every Fernet token is well over
    # 60 bytes. Use a generous lower bound + the version byte check.
    if len(raw) < 57:
        return False
    return raw[0] == 0x80
