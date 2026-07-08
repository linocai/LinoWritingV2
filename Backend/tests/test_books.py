from __future__ import annotations


def test_books_crud(client, auth_headers):
    create = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "长夜", "cover_color": "#3A86FF"},
    )
    assert create.status_code == 201
    book = create.json()
    assert book["title"] == "长夜"
    assert book["chapter_count"] == 0
    assert book["character_count"] == 0

    patch = client.patch(
        f"/api/v1/books/{book['id']}",
        headers=auth_headers,
        json={"world_setting": "雨城与旧案。"},
    )
    assert patch.status_code == 200
    assert patch.json()["world_setting"] == "雨城与旧案。"

    touch = client.post(f"/api/v1/books/{book['id']}/touch", headers=auth_headers)
    assert touch.status_code == 204

    list_response = client.get("/api/v1/books", headers=auth_headers)
    assert list_response.status_code == 200
    assert len(list_response.json()["items"]) == 1

    delete = client.delete(f"/api/v1/books/{book['id']}", headers=auth_headers)
    assert delete.status_code == 204

    missing = client.get(f"/api/v1/books/{book['id']}", headers=auth_headers)
    assert missing.status_code == 404
