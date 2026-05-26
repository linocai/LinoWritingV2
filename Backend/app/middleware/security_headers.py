"""v0.8 T-2 (§5.T): outbound response security headers.

Adds three headers to every response:

- ``Strict-Transport-Security: max-age=31536000`` — HSTS for 1 year.
  Crucially **without** ``includeSubDomains``: §5.T.5 documents that the
  author's apex ``linotsai.top`` has sibling subdomains (``100j``,
  ``lf``, …) and force-locking every one of them to HTTPS-only is a
  blast radius we don't need for the LinoWriting subdomain alone. Only
  emitted when the request reached us over HTTPS (or, in front of an
  HTTPS terminator, when the proxy set ``X-Forwarded-Proto: https``).
- ``X-Content-Type-Options: nosniff`` — defence against browser MIME
  sniffing turning a JSON response into executable HTML/JS. Always on.
- ``X-Frame-Options: DENY`` — refuse iframe embedding. LinoI is native;
  no legit caller embeds this backend in an iframe. Always on.
"""
from __future__ import annotations

from typing import Awaitable, Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware


HSTS_VALUE = "max-age=31536000"


def _is_https(request: Request) -> bool:
    """Return True if the original client-facing scheme was HTTPS.

    Two signals:

    1. ``request.url.scheme == "https"`` — direct TLS to uvicorn (rare
       in HZ prod where Nginx terminates TLS, but the path that the
       tests use via TestClient when we feed it a https:// base url).
    2. ``X-Forwarded-Proto: https`` — Nginx terminates TLS and forwards
       cleartext to uvicorn on ``127.0.0.1``. The §5.S.3 nginx site we
       deploy sets ``proxy_set_header X-Forwarded-Proto $scheme;`` so
       this header is trustworthy *in our deployment*. We do **not**
       enable Starlette's ``ProxyHeadersMiddleware``-style rewrite of
       ``request.url.scheme`` because we only need the boolean for this
       one decision; rewriting could surprise other code paths.
    """
    if request.url.scheme == "https":
        return True
    forwarded = request.headers.get("x-forwarded-proto", "")
    return forwarded.lower() == "https"


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        response = await call_next(request)
        if _is_https(request):
            # Only set HSTS on HTTPS responses. Setting it on a plain
            # http:// response is harmless on most browsers but technically
            # spec-violating, and would confuse anyone reading the headers
            # while debugging a misconfigured reverse proxy.
            response.headers.setdefault("Strict-Transport-Security", HSTS_VALUE)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response
