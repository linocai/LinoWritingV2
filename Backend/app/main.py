from __future__ import annotations

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.auth import require_bearer_token
from app.config import get_settings
from app.errors import install_exception_handlers
from app.llm.grok import GrokClient
from app.routers import admin, books, chapters, characters, health


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Lino Writing v2 Backend", version="0.1.0")
    app.state.llm_client = GrokClient(settings)

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
    app.include_router(admin.router, prefix="/api/v1", dependencies=dependencies)
    return app


app = create_app()
