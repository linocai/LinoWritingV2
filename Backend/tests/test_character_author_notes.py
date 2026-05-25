"""Phase L-1 (§5.L.3) — exercise the new ``author_notes`` column / schema slot.

Covers:
- create with author_notes round-trips through GET.
- create without author_notes defaults to ``{}``.
- PATCH author_notes replaces the whole object (same semantics as
  ``frozen_fields`` / ``live_fields``).
- PATCH without author_notes does not clobber existing notes (``exclude_unset``).
- A row inserted directly via the ORM without going through the
  ``author_notes`` code path still reads back as ``{}`` (the SQLAlchemy
  default kicks in, mirroring the migration's server-side default).
"""
from __future__ import annotations

from app.models.character import Character


def _make_book(client, auth_headers) -> dict:
    return client.post("/api/v1/books", headers=auth_headers, json={"title": "长夜"}).json()


def test_create_character_with_author_notes_round_trips(client, auth_headers):
    book = _make_book(client, auth_headers)
    notes = {"motivation": "为妹妹复仇", "secret": "童年纵火"}

    create = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={
            "name": "林夕",
            "role": "主角",
            "author_notes": notes,
        },
    )
    assert create.status_code == 201
    assert create.json()["author_notes"] == notes

    fetched = client.get(f"/api/v1/characters/{create.json()['id']}", headers=auth_headers)
    assert fetched.status_code == 200
    assert fetched.json()["author_notes"] == notes


def test_create_character_without_author_notes_defaults_empty(client, auth_headers):
    book = _make_book(client, auth_headers)
    create = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "无名"},
    )
    assert create.status_code == 201
    assert create.json()["author_notes"] == {}


def test_patch_author_notes_replaces_whole_object(client, auth_headers):
    book = _make_book(client, auth_headers)
    create = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "author_notes": {"a": 1, "b": 2}},
    ).json()

    # Whole-object replace: send {"c": 3} → old keys are gone.
    patch = client.patch(
        f"/api/v1/characters/{create['id']}",
        headers=auth_headers,
        json={"author_notes": {"c": 3}},
    )
    assert patch.status_code == 200
    assert patch.json()["author_notes"] == {"c": 3}


def test_patch_without_author_notes_preserves_existing(client, auth_headers):
    book = _make_book(client, auth_headers)
    notes = {"motivation": "为妹妹复仇"}
    create = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "author_notes": notes},
    ).json()

    # PATCH something unrelated — author_notes must not be touched.
    patch = client.patch(
        f"/api/v1/characters/{create['id']}",
        headers=auth_headers,
        json={"role": "侦探"},
    )
    assert patch.status_code == 200
    assert patch.json()["role"] == "侦探"
    assert patch.json()["author_notes"] == notes


def test_orm_default_supplies_empty_author_notes_when_unset(client, auth_headers, db_session):
    """An ORM insert without specifying author_notes must still GET as ``{}``.

    L-1 reviewer 🟡 #1: this test exercises SQLAlchemy's ``default=dict``
    fallback (not the migration's ``server_default '{}'`` or defensive
    UPDATE). The migration's own paths were verified by builder against
    a copy of the dev DB before commit. Both safety nets together mean
    a pre-migration character row can never round-trip as None.
    """
    book = _make_book(client, auth_headers)

    legacy = Character(book_id=book["id"], name="旧角色")
    db_session.add(legacy)
    db_session.commit()
    db_session.refresh(legacy)

    fetched = client.get(f"/api/v1/characters/{legacy.id}", headers=auth_headers)
    assert fetched.status_code == 200
    assert fetched.json()["author_notes"] == {}


def test_patch_author_notes_rejects_non_dict_payload(client, auth_headers):
    """L-1 reviewer 🟡 #3: lock the contract that author_notes must be a
    JSON object, not a list / string / number. Pydantic gives us this for
    free via the field's typing, but having an explicit regression test
    means a future schema relaxation can't quietly open the door.
    """
    book = _make_book(client, auth_headers)
    created = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "测试", "author_notes": {"ok": "this is a dict"}},
    ).json()

    for bad_payload in ({"author_notes": ["a", "b"]},
                       {"author_notes": "not a dict"},
                       {"author_notes": 42}):
        resp = client.patch(
            f"/api/v1/characters/{created['id']}",
            headers=auth_headers,
            json=bad_payload,
        )
        assert resp.status_code == 422, f"expected 422 for {bad_payload!r}"
        assert resp.json()["error"]["kind"] == "validation"


def test_patch_ignores_unknown_and_readonly_fields(client, auth_headers):
    """L-1 reviewer 🟡 #2: even if a future schema mistake exposes a
    read-only field, the router-side PATCHABLE_CHARACTER_FIELDS allowlist
    must drop it. We can't test this purely from the HTTP boundary because
    Pydantic would reject the extra field at the schema layer first — but
    the regression target is that the constant itself stays correct.
    """
    from app.routers.characters import PATCHABLE_CHARACTER_FIELDS

    assert PATCHABLE_CHARACTER_FIELDS == frozenset(
        {"name", "role", "frozen_fields", "live_fields", "author_notes"}
    )
