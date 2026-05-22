from __future__ import annotations


def test_characters_crud(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "长夜"}).json()
    create = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "frozen_fields": {"core_traits": "谨慎、敏锐"},
            "live_fields": {"current_status": "调查失踪案"},
        },
    )
    assert create.status_code == 201
    character = create.json()
    assert character["book_id"] == book["id"]

    patch = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"live_fields": {"current_status": "进入山洞"}},
    )
    assert patch.status_code == 200
    assert patch.json()["live_fields"]["current_status"] == "进入山洞"

    list_response = client.get(f"/api/v1/books/{book['id']}/characters", headers=auth_headers)
    assert len(list_response.json()["items"]) == 1

    delete = client.delete(f"/api/v1/characters/{character['id']}", headers=auth_headers)
    assert delete.status_code == 204
