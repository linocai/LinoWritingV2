from __future__ import annotations

import pytest
from sqlalchemy.orm import Session, sessionmaker

from app.errors import AppError
from app.llm.factory import build_llm_client, load_active_provider_key
from app.llm.openai_compatible import OpenAICompatibleClient
from app.main import app
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from app.llm.base import get_llm_client


def _seed_active_key(session: Session, **overrides) -> ProviderKey:
    fields = {
        "key_label": "Active",
        "provider_hint": "xai",
        "base_url": "https://api.x.ai/v1",
        "api_key": "sk-factory-test-ABCD",
        "model_name": "grok-4",
    }
    fields.update(overrides)
    key = ProviderKey(**fields)
    session.add(key)
    session.flush()
    settings_row = session.get(SystemSettings, 1)
    if settings_row is None:
        session.add(SystemSettings(id=1, active_provider_key_id=key.id))
    else:
        settings_row.active_provider_key_id = key.id
    session.commit()
    session.refresh(key)
    return key


def test_load_active_provider_key_returns_row_when_active(
    db_session: Session,
) -> None:
    key = _seed_active_key(db_session)
    loaded = load_active_provider_key(db_session)
    assert loaded is not None
    assert loaded.id == key.id
    assert loaded.api_key == "sk-factory-test-ABCD"


def test_load_active_provider_key_returns_none_when_settings_row_missing(
    db_session: Session,
) -> None:
    # Fresh DB: no system_settings row at all.
    assert load_active_provider_key(db_session) is None


def test_load_active_provider_key_returns_none_when_active_id_null(
    db_session: Session,
) -> None:
    db_session.add(SystemSettings(id=1, active_provider_key_id=None))
    db_session.commit()
    assert load_active_provider_key(db_session) is None


def test_build_llm_client_returns_openai_compatible_client(
    db_session: Session,
) -> None:
    _seed_active_key(db_session, api_key="sk-build-XYZ", model_name="gpt-5")
    client = build_llm_client(db_session)
    assert isinstance(client, OpenAICompatibleClient)
    assert client.api_key == "sk-build-XYZ"
    assert client.model_name == "gpt-5"
    assert client.base_url == "https://api.x.ai/v1"


def test_build_llm_client_strips_trailing_slash_on_base_url(
    db_session: Session,
) -> None:
    _seed_active_key(db_session, base_url="https://openrouter.ai/api/v1/")
    client = build_llm_client(db_session)
    assert client.base_url == "https://openrouter.ai/api/v1"


def test_build_llm_client_raises_upstream_when_no_active_key(
    db_session: Session,
) -> None:
    with pytest.raises(AppError) as excinfo:
        build_llm_client(db_session)
    assert excinfo.value.kind == "upstream"
    assert excinfo.value.message == "no_active_llm_key"
    assert excinfo.value.retryable is False


def test_expand_returns_upstream_envelope_when_no_active_key(
    client, auth_headers, session_factory: sessionmaker[Session]
) -> None:
    """Without a mocked llm dependency, the factory path runs and surfaces the
    standard error envelope to the HTTP caller (kind=upstream)."""

    # Remove the test stub so the real factory runs.
    app.dependency_overrides.pop(get_llm_client, None)

    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "无 key", "cover_color": "#222"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "甲", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "本章意图。"},
    ).json()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand",
        headers=auth_headers,
    )
    assert response.status_code == 502
    body = response.json()
    assert body["error"]["kind"] == "upstream"
    assert body["error"]["message"] == "no_active_llm_key"


def test_deleting_active_key_makes_expand_fail_upstream(
    client, auth_headers
) -> None:
    """Create a key, activate it, then delete it — subsequent expand call
    must return upstream(no_active_llm_key) since the active pointer is
    cleared on delete."""

    created = client.post(
        "/api/v1/provider_keys",
        headers=auth_headers,
        json={
            "key_label": "tmp",
            "provider_hint": "xai",
            "base_url": "https://api.x.ai/v1",
            "api_key": "sk-tmp-LAST",
            "model_name": "grok-4",
        },
    ).json()
    client.put(
        "/api/v1/settings/active_provider_key",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    client.delete(f"/api/v1/provider_keys/{created['id']}", headers=auth_headers)

    # Now strip the mock so the factory runs for real.
    app.dependency_overrides.pop(get_llm_client, None)

    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "已删", "cover_color": "#333"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "乙", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "也是意图。"},
    ).json()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand",
        headers=auth_headers,
    )
    assert response.status_code == 502
    assert response.json()["error"]["kind"] == "upstream"
    assert response.json()["error"]["message"] == "no_active_llm_key"


def test_write_sse_returns_upstream_envelope_when_no_active_key(
    client, auth_headers
) -> None:
    """SSE /write must surface the same envelope before any stream chunk
    is yielded. The factory failure happens inside Depends(get_llm_client),
    so the handler never enters its body — FastAPI's exception handler
    turns this into a plain JSON 502, not a partial SSE stream.

    Locks the contract demanded by PROJECT_PLAN §5.E.7 #7 (SSE 路径预实例化)."""

    app.dependency_overrides.pop(get_llm_client, None)

    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "SSE 无 key", "cover_color": "#444"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "丙", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "本章意图。"},
    ).json()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/write",
        headers=auth_headers,
    )
    assert response.status_code == 502
    body = response.json()
    assert body["error"]["kind"] == "upstream"
    assert body["error"]["message"] == "no_active_llm_key"
    # Critical: the response must be a normal JSON envelope, not an SSE
    # stream that opened a 200 then errored mid-flight.
    assert response.headers.get("content-type", "").startswith("application/json")
