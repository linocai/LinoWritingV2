from __future__ import annotations


def _create_key(client, auth_headers, **overrides):
    payload = {
        "key_label": "主 Grok",
        "provider_hint": "xai",
        "base_url": "https://api.x.ai/v1",
        "api_key": "sk-secret-abcdefgh1234",
        "model_name": "grok-4",
    }
    payload.update(overrides)
    response = client.post("/api/v1/provider_keys", headers=auth_headers, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def test_create_and_list_returns_masked_api_key(client, auth_headers):
    created = _create_key(client, auth_headers)
    assert created["api_key"] == "****1234"
    assert created["key_label"] == "主 Grok"
    assert created["base_url"] == "https://api.x.ai/v1"
    assert created["model_name"] == "grok-4"
    assert "id" in created

    listed = client.get("/api/v1/provider_keys", headers=auth_headers)
    assert listed.status_code == 200
    items = listed.json()["items"]
    assert len(items) == 1
    assert items[0]["api_key"] == "****1234"
    assert items[0]["id"] == created["id"]


def test_patch_without_api_key_does_not_clear_it(client, auth_headers):
    created = _create_key(client, auth_headers)
    response = client.patch(
        f"/api/v1/provider_keys/{created['id']}",
        headers=auth_headers,
        json={"key_label": "Renamed"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["key_label"] == "Renamed"
    # api_key field unchanged → mask still reflects original tail
    assert body["api_key"] == "****1234"


def test_patch_replacing_api_key_updates_mask(client, auth_headers):
    created = _create_key(client, auth_headers)
    response = client.patch(
        f"/api/v1/provider_keys/{created['id']}",
        headers=auth_headers,
        json={"api_key": "sk-new-rotated-WXYZ"},
    )
    assert response.status_code == 200
    assert response.json()["api_key"] == "****WXYZ"

    fetched = client.get("/api/v1/provider_keys", headers=auth_headers)
    assert fetched.json()["items"][0]["api_key"] == "****WXYZ"


def test_delete_active_key_resets_active_setting(client, auth_headers):
    created = _create_key(client, auth_headers)
    # Set as active
    activate = client.put(
        "/api/v1/settings/active_provider_key",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    assert activate.status_code == 200
    assert activate.json()["active_provider_key_id"] == created["id"]

    # Delete the active key
    delete = client.delete(f"/api/v1/provider_keys/{created['id']}", headers=auth_headers)
    assert delete.status_code == 204

    # Active should be reset to null
    active = client.get("/api/v1/settings/active_provider_key", headers=auth_headers)
    assert active.status_code == 200
    body = active.json()
    assert body["active_provider_key_id"] is None
    assert body["active_provider_key"] is None


def test_set_active_returns_summary_with_masked_key(client, auth_headers):
    created = _create_key(client, auth_headers, api_key="abcdef-tail-LAST")
    response = client.put(
        "/api/v1/settings/active_provider_key",
        headers=auth_headers,
        json={"provider_key_id": created["id"]},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["active_provider_key_id"] == created["id"]
    summary = body["active_provider_key"]
    assert summary["id"] == created["id"]
    assert summary["model_name"] == "grok-4"
    assert summary["provider_hint"] == "xai"
    assert summary["key_label"] == "主 Grok"
    assert summary["api_key"] == "****LAST"


def test_set_active_with_unknown_id_returns_404(client, auth_headers):
    response = client.put(
        "/api/v1/settings/active_provider_key",
        headers=auth_headers,
        json={"provider_key_id": "00000000-0000-0000-0000-000000000000"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["kind"] == "not_found"


def test_get_active_when_unset_returns_null(client, auth_headers):
    response = client.get("/api/v1/settings/active_provider_key", headers=auth_headers)
    assert response.status_code == 200
    body = response.json()
    assert body["active_provider_key_id"] is None
    assert body["active_provider_key"] is None


def test_list_without_auth_returns_401(client):
    response = client.get("/api/v1/provider_keys")
    assert response.status_code == 401


def test_create_without_auth_returns_401(client):
    response = client.post(
        "/api/v1/provider_keys",
        json={
            "key_label": "x",
            "base_url": "https://example.com/v1",
            "api_key": "abc1234",
            "model_name": "grok-4",
        },
    )
    assert response.status_code == 401


def test_patch_unknown_id_returns_404(client, auth_headers):
    response = client.patch(
        "/api/v1/provider_keys/does-not-exist",
        headers=auth_headers,
        json={"key_label": "x"},
    )
    assert response.status_code == 404
