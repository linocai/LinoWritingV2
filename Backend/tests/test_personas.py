from __future__ import annotations

# v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §5.4) — agent persona CRUD.
#
# NOTE on test DB: the conftest builds the schema via
# ``Base.metadata.create_all`` (not ``alembic upgrade``), so the migration's
# seed insert does NOT run here. The persona service materialises the three
# defaults in-memory when rows are absent, so GET still returns the three
# seed personas with is_default=true — which is the observable contract.

from app.services.personas import DEFAULT_PERSONAS

EXPECTED_ROLES = {"expander", "writer", "extractor"}


def test_list_personas_returns_three_defaults(client, auth_headers):
    resp = client.get("/api/v1/agent-personas", headers=auth_headers)
    assert resp.status_code == 200
    personas = resp.json()["personas"]
    assert len(personas) == 3
    roles = {p["agent_role"] for p in personas}
    assert roles == EXPECTED_ROLES
    for p in personas:
        assert p["is_default"] is True
        # Each default prompt matches the code-level constant.
        assert p["system_prompt"] == DEFAULT_PERSONAS[p["agent_role"]]
        assert p["system_prompt"].strip() != ""


def test_patch_persona_marks_non_default(client, auth_headers):
    resp = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"system_prompt": "我的自定义 Writer 人格。"},
    )
    assert resp.status_code == 200
    persona = resp.json()["persona"]
    assert persona["agent_role"] == "writer"
    assert persona["system_prompt"] == "我的自定义 Writer 人格。"
    assert persona["is_default"] is False

    # The change persists and is reflected in the list.
    listed = client.get("/api/v1/agent-personas", headers=auth_headers).json()["personas"]
    writer = next(p for p in listed if p["agent_role"] == "writer")
    assert writer["system_prompt"] == "我的自定义 Writer 人格。"
    assert writer["is_default"] is False
    # Other roles remain default.
    extractor = next(p for p in listed if p["agent_role"] == "extractor")
    assert extractor["is_default"] is True


def test_reset_persona_restores_default(client, auth_headers):
    # First edit it away from default.
    client.patch(
        "/api/v1/agent-personas/expander",
        headers=auth_headers,
        json={"system_prompt": "临时改过的 Expander。"},
    )
    edited = client.get("/api/v1/agent-personas", headers=auth_headers).json()["personas"]
    assert next(p for p in edited if p["agent_role"] == "expander")["is_default"] is False

    # Reset restores the default prompt and is_default=true.
    reset = client.post("/api/v1/agent-personas/expander/reset", headers=auth_headers)
    assert reset.status_code == 200
    persona = reset.json()["persona"]
    assert persona["is_default"] is True
    assert persona["system_prompt"] == DEFAULT_PERSONAS["expander"]


def test_patch_invalid_role_is_404(client, auth_headers):
    resp = client.patch(
        "/api/v1/agent-personas/architect",  # not a real role (architect was deleted)
        headers=auth_headers,
        json={"system_prompt": "x"},
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["kind"] == "not_found"


def test_reset_invalid_role_is_404(client, auth_headers):
    resp = client.post("/api/v1/agent-personas/nope/reset", headers=auth_headers)
    assert resp.status_code == 404


def test_patch_empty_system_prompt_is_422(client, auth_headers):
    empty = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"system_prompt": ""},
    )
    assert empty.status_code == 422
    assert empty.json()["error"]["kind"] == "validation"

    # Whitespace-only is also rejected.
    blank = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"system_prompt": "   \n\t  "},
    )
    assert blank.status_code == 422
