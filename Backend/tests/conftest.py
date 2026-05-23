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
os.environ.setdefault("DATABASE_URL", "sqlite+pysqlite://")

from app.config import Settings, get_settings
from app.db import Base, get_db, make_engine
from app.llm.base import get_llm_client
from app.main import app
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


@pytest.fixture()
def session_factory() -> Iterator[sessionmaker[Session]]:
    engine = make_engine("sqlite+pysqlite://")
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
    def override_db() -> Iterator[Session]:
        with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_settings] = lambda: Settings(
        api_token=TEST_TOKEN,
        database_url="sqlite+pysqlite://",
    )
    # v0.6+: get_llm_client is a DB-driven dependency; tests stub it directly
    # so we never need a real ProviderKey row for the happy path.
    app.dependency_overrides[get_llm_client] = lambda: MockLLMClient()

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()


@pytest.fixture()
def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TEST_TOKEN}"}
