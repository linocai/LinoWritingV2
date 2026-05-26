from __future__ import annotations

import json
import os
from collections.abc import Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

TEST_TOKEN = "test-token-value"
os.environ.setdefault("API_TOKEN", TEST_TOKEN)
# v0.8 S-1: tests honour an externally-set DATABASE_URL (e.g. when running
# against a local Postgres container to catch dialect-only bugs before HZ
# cutover). Default stays SQLite in-memory for the fast dev cycle.
os.environ.setdefault("DATABASE_URL", "sqlite+pysqlite://")
TEST_DATABASE_URL = os.environ["DATABASE_URL"]

# v0.8 T-1: provide a deterministic Fernet KEK so every test (Settings
# construction, encryption helpers, provider_key router roundtrips) sees a
# valid key without needing the host's real ``KEK_SECRET``. ``setdefault``
# means an operator can still override it from the shell when they want to
# verify a specific key value end-to-end. The literal below is a freshly
# generated test-only key — DO NOT use it in production.
os.environ.setdefault(
    "KEK_SECRET",
    "udGFLEj2W2PMtAu_q4xKmDNljLX_mxTXuPLo2qhzKWE=",
)
TEST_KEK_SECRET = os.environ["KEK_SECRET"]

from app.config import Settings, get_settings
from app.db import Base, get_db, make_engine
from app.llm.base import (
    get_expander_llm_client,
    get_extractor_llm_client,
    get_llm_client,
    get_writer_llm_client,
)
from app.main import app
from app.middleware.rate_limit import reset_limiter
from app import models  # noqa: F401


class MockLLMClient:
    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        return "完成"

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        context = json.loads(user)
        if "all_characters" in context:
            character_ids = [character["id"] for character in context["all_characters"]]
            return {
                "chapter_goal": "让主角发现山洞中的线索。",
                "must_happen": ["主角发现一枚带血的铜钱"],
                "must_not_happen": ["不要揭晓幕后黑手"],
                "characters_involved": character_ids[:1],
                "scene_setting": "雨夜山洞",
                "narrative_pov": "third_person_limited",
                "target_word_count": 800,
                "extra_notes": "保持悬疑感",
            }
        character = context["characters"][0]
        live_fields = dict(character.get("live_fields") or {})
        live_fields["current_status"] = "带着铜钱离开山洞"
        return {
            "summary": "主角在雨夜山洞中发现带血铜钱，意识到失踪案另有隐情，并决定继续追查。",
            "timeline_events": [
                {
                    "character_id": character["id"],
                    "event_type": "action",
                    "event_text": "在山洞中发现带血铜钱。",
                }
            ],
            "character_updates": [
                {
                    "character_id": character["id"],
                    "live_fields_patch": live_fields,
                }
            ],
        }

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[str]:
        yield "雨声压低了山洞里的呼吸。"
        yield "林夕在石缝中摸到一枚带血的铜钱。"


# v0.7 M-1: tuple of every per-Agent LLM dependency the routers may
# resolve. Exported as a module-level constant so tests can override
# (or clear) all of them in one shot — see ``override_all_llm_clients``
# and ``clear_all_llm_overrides`` below.
ALL_LLM_DEPENDENCIES = (
    get_llm_client,
    get_writer_llm_client,
    get_extractor_llm_client,
    get_expander_llm_client,
)


def override_all_llm_clients(factory) -> None:
    """Replace every LLM dependency in :data:`ALL_LLM_DEPENDENCIES` with
    ``factory`` (a zero-arg callable returning an LLMClient).

    Use from a test when you want a single mock to back every Agent. The
    generic ``app.dependency_overrides[get_llm_client] = ...`` pattern from
    v0.6 only covers endpoints that haven't been re-routed to per-Agent
    dependencies; this helper makes the swap behaviour-equivalent across
    the entire surface.
    """
    for dep in ALL_LLM_DEPENDENCIES:
        app.dependency_overrides[dep] = factory


def clear_all_llm_overrides() -> None:
    """Remove all LLM dependency overrides set by the conftest or by an
    earlier ``override_all_llm_clients`` call.

    Use this before a test that needs the real factory path (e.g. asserts
    ``upstream("no_active_llm_key")`` when no ProviderKey is configured).
    """
    for dep in ALL_LLM_DEPENDENCIES:
        app.dependency_overrides.pop(dep, None)


@pytest.fixture()
def session_factory() -> Iterator[sessionmaker[Session]]:
    # v0.8 S-1: same engine URL the conftest reads at import time. When the
    # operator sets `DATABASE_URL=postgresql+psycopg://...` before invoking
    # pytest, every per-test schema is created/dropped on the live PG instance,
    # which is exactly the dialect verification we want before HZ cutover.
    engine = make_engine(TEST_DATABASE_URL)
    Base.metadata.create_all(bind=engine)
    factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)
    try:
        yield factory
    finally:
        Base.metadata.drop_all(bind=engine)
        engine.dispose()


@pytest.fixture()
def db_session(session_factory: sessionmaker[Session]) -> Iterator[Session]:
    with session_factory() as session:
        yield session


@pytest.fixture()
def client(session_factory: sessionmaker[Session]) -> Iterator[TestClient]:
    # v0.8 T-2 (§5.T): rate-limit counters live in-process. Clearing them
    # at the start of every ``client`` fixture means each test starts
    # with a fresh budget — otherwise the global Bearer token "test-token-value"
    # would accumulate hits across the whole suite and the 31st write in
    # *any* test could trip the limit unrelated to the test's intent.
    reset_limiter()

    def override_db() -> Iterator[Session]:
        with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_settings] = lambda: Settings(
        api_token=TEST_TOKEN,
        database_url=TEST_DATABASE_URL,
        # v0.8 T-1: Settings requires a valid Fernet ``kek_secret`` now.
        # Without this the dependency override would raise ValidationError
        # the first time a router resolves ``Depends(get_settings)``.
        kek_secret=TEST_KEK_SECRET,
    )
    # v0.6+: get_llm_client is a DB-driven dependency; tests stub it directly
    # so we never need a real ProviderKey row for the happy path.
    app.dependency_overrides[get_llm_client] = lambda: MockLLMClient()
    # v0.7 M-1 (§5.M): every Agent-specific endpoint declares a per-Agent
    # dependency; stub all three to the same Mock by default so v0.6-era
    # tests (and any new test that doesn't care about per-Agent routing)
    # keep working without having to set up a ProviderKey row.
    # Per-Agent tests can still override an individual one to inject a
    # different mock per Agent.
    app.dependency_overrides[get_writer_llm_client] = lambda: MockLLMClient()
    app.dependency_overrides[get_extractor_llm_client] = lambda: MockLLMClient()
    app.dependency_overrides[get_expander_llm_client] = lambda: MockLLMClient()

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()


@pytest.fixture()
def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TEST_TOKEN}"}
