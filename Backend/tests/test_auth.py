from __future__ import annotations


def test_auth_required(client):
    response = client.get("/api/v1/health")
    assert response.status_code == 401
    assert response.json()["error"]["kind"] == "unauthorized"


def test_auth_rejects_wrong_token(client):
    response = client.get("/api/v1/health", headers={"Authorization": "Bearer wrong"})
    assert response.status_code == 401
    assert response.json()["error"]["kind"] == "unauthorized"


def test_health_with_token(client, auth_headers):
    response = client.get("/api/v1/health", headers=auth_headers)
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "0.5.0"}


def test_framework_errors_use_contract_shape(client, auth_headers):
    missing = client.get("/api/v1/not-a-route", headers=auth_headers)
    assert missing.status_code == 404
    assert missing.json()["error"]["kind"] == "not_found"

    wrong_method = client.post("/api/v1/health", headers=auth_headers)
    assert wrong_method.status_code == 405
    assert wrong_method.json()["error"]["kind"] == "validation"
