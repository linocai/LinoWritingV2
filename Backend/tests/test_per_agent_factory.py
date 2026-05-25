"""v0.7 Phase M-1 — per-Agent LLM factory + per-Agent active key endpoints.

Covers the contract from §5.M:

* :func:`build_llm_client(db, agent_role=...)` prefers the per-Agent key.
* Per-Agent key absent + generic active set → falls back to generic
  (the §5.M.3 backward-compatibility guarantee).
* Per-Agent absent + generic absent → raises ``upstream("no_active_llm_key")``.
* The new ``/api/v1/settings/active_key/{agent_role}`` endpoint pair.
* End-to-end: configuring Writer→key A while Extractor→key B routes
  ``/write`` to A and ``/finalize`` to B (with per-Agent dependency
  overrides standing in for real HTTP-bound key dispatch).
"""
from __future__ import annotations

from typing import Any

import pytest
from sqlalchemy.orm import Session, sessionmaker

from app.errors import AppError
from app.llm.base import (
    get_expander_llm_client,
    get_extractor_llm_client,
    get_writer_llm_client,
)
from app.llm.factory import (
    build_llm_client,
    load_active_provider_key_for_agent,
)
from app.llm.openai_compatible import OpenAICompatibleClient
from app.main import app
from app.models.provider_key import ProviderKey
from app.models.system_settings import SystemSettings
from tests.conftest import (
    MockLLMClient,
    clear_all_llm_overrides,
)


# ----- low-level factory unit tests -----


def _insert_key(
    session: Session,
    *,
    label: str = "k",
    api_key: str = "sk-test-AAAA",
    model: str = "grok-4",
    agent_role: str | None = None,
) -> ProviderKey:
    key = ProviderKey(
        key_label=label,
        provider_hint="xai",
        base_url="https://api.x.ai/v1",
        api_key=api_key,
        model_name=model,
        agent_role=agent_role,
    )
    session.add(key)
    session.flush()
    return key


def _ensure_settings(session: Session) -> SystemSettings:
    row = session.get(SystemSettings, 1)
    if row is None:
        row = SystemSettings(id=1)
        session.add(row)
        session.flush()
    return row


def test_build_llm_client_prefers_per_agent_key(db_session: Session) -> None:
    """When both generic and writer active keys are set, writer wins."""
    generic = _insert_key(db_session, label="generic", api_key="sk-GENERIC-9999")
    writer_key = _insert_key(
        db_session,
        label="writer-claude",
        api_key="sk-WRITER-1111",
        model="anthropic/claude-sonnet-4.5",
        agent_role="writer",
    )
    row = _ensure_settings(db_session)
    row.active_provider_key_id = generic.id
    row.active_writer_key_id = writer_key.id
    db_session.commit()

    client = build_llm_client(db_session, agent_role="writer")
    assert isinstance(client, OpenAICompatibleClient)
    assert client.api_key == "sk-WRITER-1111"
    assert client.model_name == "anthropic/claude-sonnet-4.5"


def test_build_llm_client_falls_back_to_generic_when_per_agent_unset(
    db_session: Session,
) -> None:
    """The §5.M.3 backward-compatibility guarantee: writer slot empty →
    factory still returns the generic active key (v0.6 behaviour)."""
    generic = _insert_key(db_session, label="generic", api_key="sk-GENERIC-2222")
    row = _ensure_settings(db_session)
    row.active_provider_key_id = generic.id
    # Deliberately do NOT set active_writer_key_id.
    db_session.commit()

    client = build_llm_client(db_session, agent_role="writer")
    assert isinstance(client, OpenAICompatibleClient)
    assert client.api_key == "sk-GENERIC-2222"


def test_build_llm_client_raises_when_no_key_resolves(
    db_session: Session,
) -> None:
    """Per-Agent slot empty AND generic empty → upstream(no_active_llm_key)."""
    # Fresh DB: no system_settings row, no keys.
    with pytest.raises(AppError) as exc:
        build_llm_client(db_session, agent_role="extractor")
    assert exc.value.kind == "upstream"
    # v0.7 §5.N — message is now Chinese; sentinel moved to details.code.
    assert exc.value.details.get("code") == "no_active_llm_key"


def test_build_llm_client_without_agent_role_matches_v06_behavior(
    db_session: Session,
) -> None:
    """Calling ``build_llm_client(db)`` without an agent_role keeps the
    v0.6 signature: returns the generic active key, ignores per-Agent
    pointers entirely. This proves we did not change call-site semantics
    for code paths that never opt in to per-Agent routing."""
    generic = _insert_key(db_session, label="generic", api_key="sk-GENERIC-3333")
    writer_key = _insert_key(
        db_session, label="w", api_key="sk-W-4444", agent_role="writer"
    )
    row = _ensure_settings(db_session)
    row.active_provider_key_id = generic.id
    row.active_writer_key_id = writer_key.id
    db_session.commit()

    client = build_llm_client(db_session)  # no agent_role
    assert client.api_key == "sk-GENERIC-3333"


def test_load_active_provider_key_for_agent_stale_fk_falls_back(
    db_session: Session,
) -> None:
    """If the per-Agent FK points at a row that was deleted out-of-band
    (FK enforcement temporarily disabled, in-flight race, or a buggy
    out-of-band migration), the factory must gracefully fall back to
    generic rather than 500.

    We simulate the stale pointer by toggling SQLite's FK enforcement off
    just for the bad UPDATE — this lets us reproduce the case that on
    PostgreSQL would require a race window to hit. The toggle is local to
    this test's connection.
    """
    from sqlalchemy import text

    generic = _insert_key(db_session, label="generic", api_key="sk-GENERIC-5555")
    row = _ensure_settings(db_session)
    row.active_provider_key_id = generic.id
    db_session.commit()

    db_session.execute(text("PRAGMA foreign_keys=OFF"))
    try:
        db_session.execute(
            text(
                "UPDATE system_settings SET active_extractor_key_id = "
                ":bad WHERE id = 1"
            ),
            {"bad": "00000000-0000-0000-0000-000000000000"},
        )
        db_session.commit()
    finally:
        db_session.execute(text("PRAGMA foreign_keys=ON"))

    resolved = load_active_provider_key_for_agent(db_session, "extractor")
    assert resolved is not None
    assert resolved.id == generic.id


# ----- per-Agent active-key endpoints -----


def _create_key_api(client, auth_headers, **overrides) -> dict:
    payload = {
        "key_label": "k",
        "provider_hint": "xai",
        "base_url": "https://api.x.ai/v1",
        "api_key": "sk-secret-LAST",
        "model_name": "grok-4",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/provider_keys", headers=auth_headers, json=payload)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_create_provider_key_with_agent_role_round_trips(client, auth_headers):
    """POST /provider_keys with agent_role lands in the DB and surfaces
    in GET responses."""
    created = _create_key_api(
        client,
        auth_headers,
        key_label="writer-only",
        api_key="sk-writer-DEAD",
        agent_role="writer",
    )
    assert created["agent_role"] == "writer"

    listed = client.get("/api/v1/provider_keys", headers=auth_headers).json()
    [row] = listed["items"]
    assert row["agent_role"] == "writer"


def test_create_provider_key_without_agent_role_defaults_to_null(
    client, auth_headers
):
    created = _create_key_api(client, auth_headers, api_key="sk-generic-TAIL")
    assert created["agent_role"] is None


def test_create_provider_key_rejects_invalid_agent_role(client, auth_headers):
    """Schema layer must constrain ``agent_role`` to the three known
    values (Literal['writer','extractor','expander'])."""
    resp = client.post(
        "/api/v1/provider_keys",
        headers=auth_headers,
        json={
            "key_label": "bogus",
            "provider_hint": "xai",
            "base_url": "https://api.x.ai/v1",
            "api_key": "sk-bogus-XXXX",
            "model_name": "grok-4",
            "agent_role": "stylist",
        },
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["kind"] == "validation"


def test_patch_can_clear_agent_role_back_to_null(client, auth_headers):
    created = _create_key_api(client, auth_headers, agent_role="extractor")
    assert created["agent_role"] == "extractor"
    resp = client.patch(
        f"/api/v1/provider_keys/{created['id']}",
        headers=auth_headers,
        json={"agent_role": None},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["agent_role"] is None


def test_get_active_agent_key_when_unset_returns_null_summary(
    client, auth_headers
):
    resp = client.get(
        "/api/v1/settings/active_key/writer", headers=auth_headers
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body == {
        "agent_role": "writer",
        "active_provider_key_id": None,
        "key_label": None,
        "provider_hint": None,
        "model_name": None,
        "api_key_mask": None,
    }


def test_put_active_agent_key_with_generic_key_succeeds(client, auth_headers):
    """A generic (agent_role=None) key can be activated for any Agent slot."""
    created = _create_key_api(
        client, auth_headers, key_label="generic-grok", api_key="sk-gen-LAST"
    )
    resp = client.put(
        "/api/v1/settings/active_key/expander",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["agent_role"] == "expander"
    assert body["active_provider_key_id"] == created["id"]
    assert body["api_key_mask"] == "****LAST"


def test_put_active_agent_key_rejects_mismatched_agent_role(
    client, auth_headers
):
    """A key tagged 'extractor' cannot be activated for 'writer'."""
    extractor_key = _create_key_api(
        client, auth_headers, key_label="x", agent_role="extractor"
    )
    resp = client.put(
        "/api/v1/settings/active_key/writer",
        headers=auth_headers,
        json={"provider_key_id": extractor_key["id"]},
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"


def test_put_active_agent_key_with_null_clears_pointer(client, auth_headers):
    """Sending ``provider_key_id: null`` is the explicit "clear back to
    generic fallback" operation."""
    created = _create_key_api(
        client, auth_headers, key_label="w", agent_role="writer"
    )
    client.put(
        "/api/v1/settings/active_key/writer",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    # Now clear it.
    resp = client.put(
        "/api/v1/settings/active_key/writer",
        headers=auth_headers,
        json={"provider_key_id": None},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["active_provider_key_id"] is None
    # GET confirms.
    fetched = client.get(
        "/api/v1/settings/active_key/writer", headers=auth_headers
    ).json()
    assert fetched["active_provider_key_id"] is None


def test_put_active_agent_key_rejects_unknown_agent_role_in_path(
    client, auth_headers
):
    resp = client.put(
        "/api/v1/settings/active_key/stylist",
        headers=auth_headers,
        json={"provider_key_id": None},
    )
    assert resp.status_code == 422


def test_put_active_agent_key_rejects_unknown_provider_key_id(
    client, auth_headers
):
    resp = client.put(
        "/api/v1/settings/active_key/writer",
        headers=auth_headers,
        json={"provider_key_id": "00000000-0000-0000-0000-000000000000"},
    )
    assert resp.status_code == 404


def test_delete_provider_key_clears_every_per_agent_pointer(
    client, auth_headers
):
    """Deleting a key that was active in multiple per-Agent slots must
    null every slot — not just one. Without this, deleting a generic
    key shared across two Agents would leave stale FK pointers."""
    shared = _create_key_api(
        client, auth_headers, key_label="shared", api_key="sk-SHARE-LAST"
    )
    for role in ("writer", "extractor"):
        client.put(
            f"/api/v1/settings/active_key/{role}",
            headers=auth_headers,
            json={"provider_key_id": shared["id"]},
        )
    # Also as generic active.
    client.put(
        "/api/v1/settings/active_provider_key",
        headers=auth_headers,
        json={"provider_key_id": shared["id"]},
    )
    # Sanity check.
    assert (
        client.get(
            "/api/v1/settings/active_key/writer", headers=auth_headers
        ).json()["active_provider_key_id"]
        == shared["id"]
    )

    # Delete.
    delete = client.delete(
        f"/api/v1/provider_keys/{shared['id']}", headers=auth_headers
    )
    assert delete.status_code == 204

    # All four pointers should now be null.
    for role in ("writer", "extractor", "expander"):
        body = client.get(
            f"/api/v1/settings/active_key/{role}", headers=auth_headers
        ).json()
        assert body["active_provider_key_id"] is None, role
    generic = client.get(
        "/api/v1/settings/active_provider_key", headers=auth_headers
    ).json()
    assert generic["active_provider_key_id"] is None


# ----- end-to-end: per-Agent dependency routing -----


class _LabelledLLM(MockLLMClient):
    """MockLLMClient subclass that remembers which Agent invoked it.

    Used to prove the HTTP routers Depend on the right per-Agent client.
    Subclasses MockLLMClient so it inherits all the realistic JSON / stream
    responses the conftest mock already produces — we only care about
    *identity*, not behavior.
    """

    def __init__(self, label: str, log: dict[str, list[str]]):
        self.label = label
        self.log = log

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        self.log.setdefault(self.label, []).append("complete")
        return super().complete(system=system, user=user, **kwargs)

    def complete_json(
        self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any
    ) -> dict[str, Any]:
        self.log.setdefault(self.label, []).append("complete_json")
        return super().complete_json(
            system=system, user=user, schema=schema, **kwargs
        )

    def complete_stream(
        self, *, system: str, user: str, **kwargs: Any
    ):  # type: ignore[override]
        self.log.setdefault(self.label, []).append("complete_stream")
        return super().complete_stream(system=system, user=user, **kwargs)


def test_expand_write_finalize_route_to_their_per_agent_dependency(
    client, auth_headers
):
    """Happy path of §5.M: Writer → key W / Extractor → key E / Expander →
    key X. Each endpoint must invoke its own dependency, not the generic
    fallback. We assert this via the per-Agent dependency overrides — that
    is the contract the production factory enforces too (the factory turns
    each per-Agent key into a distinct OpenAICompatibleClient instance,
    here we just give each Agent a distinct MockLLM instance to prove the
    Depends wiring)."""
    log: dict[str, list[str]] = {}
    clear_all_llm_overrides()
    app.dependency_overrides[get_expander_llm_client] = lambda: _LabelledLLM(
        "expander", log
    )
    app.dependency_overrides[get_writer_llm_client] = lambda: _LabelledLLM(
        "writer", log
    )
    app.dependency_overrides[get_extractor_llm_client] = lambda: _LabelledLLM(
        "extractor", log
    )

    # Seed a book + character + chapter.
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "派单", "cover_color": "#321"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "甲", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "派单测试"},
    ).json()

    # /expand → expander
    resp = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers
    )
    assert resp.status_code == 200, resp.text
    # /write → writer (SSE)
    with client.stream(
        "POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers
    ) as r:
        _ = "".join(r.iter_text())
        assert r.status_code == 200
    # /finalize → extractor
    final = client.post(
        f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers
    )
    assert final.status_code == 200, final.text

    assert "complete_json" in log.get("expander", []), log
    assert "complete_stream" in log.get("writer", []), log
    assert "complete_json" in log.get("extractor", []), log
    # And critically: no cross-Agent leakage.
    assert "complete_stream" not in log.get("expander", [])
    assert "complete_stream" not in log.get("extractor", [])
    assert "complete_json" not in log.get("writer", [])


def test_v06_user_with_no_per_agent_keys_routes_through_fallback(
    client, auth_headers
):
    """The §5.M.3 backward-compatibility test, end-to-end:

    A v0.6-style deployment configures only the generic active key (no
    per-Agent overrides). The Writer / Extractor / Expander endpoints must
    still succeed and resolve via the generic fallback path inside the
    factory. We simulate the factory's resolution by routing every per-
    Agent dependency through the *generic* ``get_llm_client`` override that
    conftest installs — that is the exact behavior
    ``build_llm_client(db, 'writer')`` exhibits when
    ``active_writer_key_id`` is NULL but ``active_provider_key_id`` is set.
    """
    # conftest leaves all four LLM overrides pointing at MockLLMClient,
    # which mirrors a v0.6 deployment where every Agent resolves to the
    # generic key. We just exercise the full expand → write → finalize
    # flow and check it succeeds without 502s.
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "兼容", "cover_color": "#456"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "乙", "role": "主角"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "v0.6 兼容"},
    ).json()
    r1 = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand", headers=auth_headers
    )
    assert r1.status_code == 200, r1.text
    with client.stream(
        "POST", f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers
    ) as r2:
        _ = "".join(r2.iter_text())
        assert r2.status_code == 200
    r3 = client.post(
        f"/api/v1/chapters/{chapter['id']}/finalize", headers=auth_headers
    )
    assert r3.status_code == 200, r3.text
