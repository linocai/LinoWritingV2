"""v1.0.1 — Bearer-token authentication via a single fixed shared secret.

A request authenticates by presenting ``Authorization: Bearer <x>`` whose
``<x>`` equals ``settings.api_token``. The comparison uses
``hmac.compare_digest`` so the timing channel is uninteresting.

This replaces the v0.9 W / v1.0.0 multi-device pairing subsystem
(per-device tokens, 6-digit pair codes, QR onboarding). The app is a
single-user tool: the macOS / iOS clients each carry the one fixed
``API_TOKEN`` in Keychain and the backend compares against that one value.
``API_TOKEN`` is a required env var (see ``app.config.Settings``), so a
deployment with no token configured fails at startup rather than silently
accepting every request.
"""
from __future__ import annotations

import hmac

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings, get_settings
from app.errors import unauthorized

bearer_scheme = HTTPBearer(auto_error=False)


def require_bearer_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> None:
    """Reject the request with 401 unless the Bearer token matches the
    configured ``API_TOKEN``.

    The presented token is compared with ``hmac.compare_digest`` so the
    timing channel carries no information about how many leading characters
    matched.
    """
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized()
    if not hmac.compare_digest(credentials.credentials, settings.api_token):
        raise unauthorized()
