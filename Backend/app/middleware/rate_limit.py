"""v0.8 T-2 (§5.T): per-token rate limiting on the FastAPI surface.

Design (§5.T.2):

- Backend: ``slowapi`` (in-memory storage). HZ prod runs a single uvicorn
  worker (§5.S.2 decision) so an in-memory counter is correct and
  permanent — no Redis needed.
- Key function: the request's Bearer token. ``require_bearer_token``
  rejects unauthenticated callers with 401 before they ever reach the
  rate limiter, so the only requests we count are already authorised.
  Per-token bucketing means a leaked token can't share its budget with
  the author's own client.
- Limits:
  - **Write endpoints** (LLM-spending): 30 / minute. Allow-list below
    matches §5.T.2 verbatim — ``/chapters/{id}/expand|write|import|finalize``,
    plus (v1.3.0 II P2) ``/books/{id}/characters/parse``.
  - **All other endpoints**: 600 / minute.
- 429 envelope: we let slowapi raise :class:`RateLimitExceeded`, catch it
  in a FastAPI exception handler, and re-emit our standard AppError
  shape with ``kind="rate_limited"``, a Chinese ``message``, and
  ``details.code = "rate_limited"`` + ``details.retry_after_seconds``.
  The HTTP-level ``Retry-After`` header is set explicitly on the response.

The middleware does *not* hash or otherwise pseudonymise the token in
storage keys because the limiter state lives only in-process and is
flushed on every restart.
"""
from __future__ import annotations

import logging
from typing import Awaitable, Callable

from fastapi import FastAPI, Request, Response
from limits import parse as parse_limit_string
from slowapi import Limiter
from slowapi.errors import RateLimitExceeded
from starlette.middleware.base import BaseHTTPMiddleware

from app.errors import error_payload, i18n_rate_limited

logger = logging.getLogger(__name__)


# Cache parsed limit objects so we only run the ``limits`` parser once
# per limit string (called on every request otherwise).
_PARSED_LIMITS: dict[str, object] = {}


def _parsed(limit_string: str):
    item = _PARSED_LIMITS.get(limit_string)
    if item is None:
        item = parse_limit_string(limit_string)
        _PARSED_LIMITS[limit_string] = item
    return item


# --- Limits (§5.T.2) -------------------------------------------------------

WRITE_LIMIT = "30/minute"
DEFAULT_LIMIT = "600/minute"


def _bearer_key(request: Request) -> str:
    """Extract the Bearer token to use as the rate-limit bucket key.

    Anonymous calls fall back to the remote address: in prod they'll be
    rejected by ``require_bearer_token`` with 401 before reaching the
    limiter, but the middleware sits *outside* the dependency stack so we
    still need a sensible bucket for them. Falling back to client IP also
    means health checks / 404 probes share a single bucket per source.
    """
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return f"token:{auth[7:].strip()}"
    client = request.client
    if client is not None:
        return f"ip:{client.host}"
    return "ip:unknown"


def _is_write_endpoint(request: Request) -> bool:
    """Return True for the LLM-spending POST routes that get the tight
    30/min budget. Matches §5.T.2 exactly: only the four chapter actions
    that call out to an LLM provider or finalize an irreversible write —
    plus (v1.3.0 II P2) ``POST /books/{id}/characters/parse``, the
    character-card LLM-parse endpoint (also LLM-spending).
    """
    if request.method != "POST":
        return False
    path = request.url.path
    if path.startswith("/api/v1/chapters/"):
        # ``/api/v1/chapters/{id}/<action>`` → action segment is the last one.
        parts = path.rstrip("/").split("/")
        if len(parts) < 6:
            return False
        action = parts[-1]
        return action in {"expand", "write", "import", "finalize"}
    if path.startswith("/api/v1/books/"):
        # ``/api/v1/books/{id}/characters/parse``.
        parts = path.rstrip("/").split("/")
        return len(parts) == 7 and parts[-2] == "characters" and parts[-1] == "parse"
    return False


def _retry_after_seconds(limit_string: str) -> int:
    """Convert a slowapi limit string (e.g. ``"30/minute"``) into the
    number of seconds the client should wait before retrying.

    We return the full window length rather than the precise time-to-bucket
    reset because:

    1. slowapi's exception doesn't expose a wall-clock reset timestamp in
       a stable way across versions.
    2. The full window is a strict upper bound — never lies and never
       underestimates — which is what ``Retry-After`` semantics require.
    """
    try:
        _count, period = limit_string.split("/", 1)
    except ValueError:
        return 60
    period = period.strip().lower()
    if period.startswith("second"):
        return 1
    if period.startswith("minute"):
        return 60
    if period.startswith("hour"):
        return 3600
    if period.startswith("day"):
        return 86400
    return 60


# --- slowapi limiter singleton ---------------------------------------------

# ``headers_enabled=False`` because we emit ``Retry-After`` ourselves on the
# error response (and we don't want slowapi's standard X-RateLimit-* headers
# on every successful response — they double cache size and we don't surface
# them in any UI).
limiter = Limiter(
    key_func=_bearer_key,
    headers_enabled=False,
    auto_check=False,
)


# --- middleware ------------------------------------------------------------


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Apply the right limit to each incoming request before it hits the
    router.

    Sits outermost (before CORS) so a DDoS-style flood gets 429'd before
    we spend any CPU on Pydantic / SQLAlchemy. The trade-off: CORS
    preflight (OPTIONS) requests also count against the limit. That's
    fine — preflights are cheap on the client side and a single user
    will never make 600+ of them per minute in normal operation.
    """

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        limit_string = WRITE_LIMIT if _is_write_endpoint(request) else DEFAULT_LIMIT
        key = _bearer_key(request)

        # Hit the in-memory limiter. ``hit()`` returns True iff the
        # request is permitted (the slot was consumed); False means the
        # bucket is exhausted for this key + this window.
        try:
            allowed = limiter.limiter.hit(_parsed(limit_string), key)
        except Exception:  # pragma: no cover - defensive: never fail open silently
            logger.exception("rate limiter internal error; letting request through")
            return await call_next(request)

        if not allowed:
            return _rate_limit_response(limit_string)
        return await call_next(request)


def _rate_limit_response(limit_string: str) -> Response:
    """Build the 429 response with our AppError envelope + Retry-After."""
    retry_after = _retry_after_seconds(limit_string)
    err = i18n_rate_limited(retry_after)
    from fastapi.responses import JSONResponse

    response = JSONResponse(
        status_code=err.status_code,
        content=error_payload(err),
    )
    response.headers["Retry-After"] = str(retry_after)
    return response


def reset_limiter() -> None:
    """Test helper: clear all in-memory rate-limit counters.

    Called from ``conftest.py`` between tests so each test starts with a
    clean budget. Production code never calls this.
    """
    storage = limiter.limiter.storage
    # ``MemoryStorage`` exposes ``reset()``; other backends (Redis etc.)
    # would need their own clear logic, but slowapi defaults to memory
    # and we never override it.
    try:
        storage.reset()
    except AttributeError:
        # Older slowapi/limits exposed ``clear`` instead of ``reset``;
        # try that as a fallback before giving up.
        clear = getattr(storage, "clear", None)
        if callable(clear):
            clear()


def install_rate_limit_error_handler(app: FastAPI) -> None:
    """Register a fallback handler for any ``RateLimitExceeded`` raised
    by slowapi decorators applied directly on a route.

    The middleware above is the primary enforcement path, but this guard
    means if a future endpoint adopts the ``@limiter.limit`` decorator
    style, its 429 still goes through our AppError envelope instead of
    leaking slowapi's default text-only response.
    """

    @app.exception_handler(RateLimitExceeded)
    async def _handle(request: Request, exc: RateLimitExceeded) -> Response:
        limit_value = getattr(exc.limit, "limit", None)
        limit_string = str(limit_value) if limit_value else WRITE_LIMIT
        return _rate_limit_response(limit_string)
