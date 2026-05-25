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
    try:
        with SessionLocal() as session:
            migrate_env_provider_key(session, get_settings())
    except Exception:  # pragma: no cover - defensive, never block startup
        logger.exception("env -> provider_keys migration failed")
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Lino Writing v2 Backend", version="0.7.0", lifespan=_lifespan)
    # NB: LLM client is no longer instantiated at startup. Each request that
    # needs LLM access now calls ``build_llm_client(db)`` via the
    # ``get_llm_client`` dependency, which reads the active ``ProviderKey``
    # row from the database. See app/llm/factory.py.

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    install_exception_handlers(app)

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
