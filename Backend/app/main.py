from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.auth import require_bearer_token
from app.config import get_settings
from app.db import SessionLocal
from app.errors import install_exception_handlers
from app.middleware.access_log_filter import install_access_log_redaction
from app.middleware.rate_limit import (
    RateLimitMiddleware,
    install_rate_limit_error_handler,
)
from app.middleware.security_headers import SecurityHeadersMiddleware
from app.routers import (
    admin,
    books,
    chapters,
    characters,
    health,
    provider_keys,
    timeline_events,
)
from app.services.env_provider_migration import migrate_env_provider_key

logger = logging.getLogger(__name__)


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    # v0.8 T-2 (§5.T): mount the uvicorn access-log redaction filter
    # exactly once per process. ``install_access_log_redaction`` is
    # idempotent so re-entry (TestClient context entry/exit in the test
    # suite) doesn't stack duplicate filters.
    install_access_log_redaction()

    try:
        with SessionLocal() as session:
            migrate_env_provider_key(session, get_settings())
    except Exception:  # pragma: no cover - defensive, never block startup
        logger.exception("env -> provider_keys migration failed")
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Lino Writing v2 Backend", version="0.8.0", lifespan=_lifespan)
    # NB: LLM client is no longer instantiated at startup. Each request that
    # needs LLM access now calls ``build_llm_client(db)`` via the
    # ``get_llm_client`` dependency, which reads the active ``ProviderKey``
    # row from the database. See app/llm/factory.py.

    # v0.8 T-2 (§5.T): middleware stack ordering (outermost → innermost):
    #   1. RateLimitMiddleware  — 429 before CORS / parsing burns CPU
    #   2. CORSMiddleware       — existing behaviour
    #   3. SecurityHeadersMiddleware — HSTS / nosniff / frame-deny
    # FastAPI ``add_middleware`` prepends, so the call order is reversed:
    # the *last* add_middleware call is the outermost layer at runtime.
    app.add_middleware(SecurityHeadersMiddleware)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.add_middleware(RateLimitMiddleware)

    install_exception_handlers(app)
    install_rate_limit_error_handler(app)

    dependencies = [Depends(require_bearer_token)]
    app.include_router(health.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(books.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(characters.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(chapters.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(timeline_events.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(admin.router, prefix="/api/v1", dependencies=dependencies)
    app.include_router(provider_keys.router, prefix="/api/v1", dependencies=dependencies)

    return app


app = create_app()
