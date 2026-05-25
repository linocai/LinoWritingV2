"""Tests for POST /chapters/{id}/admin_reset (§5.P.1 E / Phase P-3).

The endpoint is the user-facing escape hatch for a chapter stranded
in ``writing`` (or any other state). It must:

- Accept any current status as input (that's the point — emergency
  override). Conflict states like ``writing`` are explicitly OK.
- Default the target to ``draft_ready``.
- Refuse target statuses outside the safe set.
- Preserve ``draft_text`` and ``structured_prompt`` so the user keeps
  whatever half-finished work was on the chapter.
- Write an ``agent_logs`` row so the rescue is auditable.
"""
from __future__ import annotations


def _seed_book_chapter(client, auth_headers, *, draft="保留我"):
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "Reset Test", "cover_color": "#000000"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "写吧。"},
    ).json()
    # Force the chapter into the requested status + draft via direct PATCH
    # is impossible (status is not patchable). Use admin_reset itself to
    # set the chapter into a non-default state via a separate path? No —
    # we manipulate the DB directly via a session created from the same
    # override-injected sessionmaker, but we don't have that handle in
    # this test. Instead, drive the chapter through expand + write to
    # get it into 'writing' is too slow.
    # Simplest: call PATCH to set draft_text, then call admin_reset to
    # reach the target status, then this fixture call is meaningless
    # because admin_reset overwrites. Compromise: just return the
    # freshly-created chapter (status=draft) plus the draft via PATCH.
    if draft is not None:
        client.patch(
            f"/api/v1/chapters/{chapter['id']}",
            headers=auth_headers,
            json={"draft_text": draft},
        )
    return book, chapter


def test_admin_reset_default_target_is_draft_ready(client, auth_headers):
    _, chapter = _seed_book_chapter(client, auth_headers)
    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "draft_ready"


def test_admin_reset_accepts_explicit_target(client, auth_headers):
    _, chapter = _seed_book_chapter(client, auth_headers)
    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
        json={"target_status": "draft"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "draft"


def test_admin_reset_rejects_unsafe_target(client, auth_headers):
    _, chapter = _seed_book_chapter(client, auth_headers)
    # 'writing' would just re-strand the chapter; 'finalized' belongs
    # to /reopen — both must be rejected at the schema layer.
    for bad in ("writing", "finalized", "garbage"):
        response = client.post(
            f"/api/v1/chapters/{chapter['id']}/admin_reset",
            headers=auth_headers,
            json={"target_status": bad},
        )
        assert response.status_code == 422, bad


def test_admin_reset_preserves_draft_text(client, auth_headers):
    _, chapter = _seed_book_chapter(client, auth_headers, draft="半成品三千字")
    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    assert response.status_code == 200
    assert response.json()["draft_text"] == "半成品三千字"
    # Double-check via a fresh GET.
    refreshed = client.get(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
    ).json()
    assert refreshed["draft_text"] == "半成品三千字"
    assert refreshed["status"] == "draft_ready"


def test_admin_reset_writes_agent_log(client, auth_headers):
    # We can't peek at the DB directly here because the conftest
    # gives each fixture its own engine; instead we assert via the
    # GET /admin/logs read endpoint.
    _, chapter = _seed_book_chapter(client, auth_headers)
    client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    logs = client.get(
        "/api/v1/admin/logs",
        headers=auth_headers,
    ).json()
    admin_logs = [
        row for row in logs["items"]
        if row.get("agent_name") == "admin_reset"
    ]
    assert len(admin_logs) == 1
    entry = admin_logs[0]
    # The input preview should mention the transition we recorded.
    assert entry["input_preview"] is not None
    assert "from_status" in entry["input_preview"]
    assert "to_status" in entry["input_preview"]
    assert "draft_ready" in entry["input_preview"]


def test_admin_reset_rescues_chapter_stuck_in_writing(client, auth_headers, session_factory):
    """The raison d'être of admin_reset: rescue a chapter stranded in
    'writing' (SSE crash, server kill mid-stream, network died). The
    normal /write and /import paths both reject writing status, so this
    endpoint is the *only* way out short of a SQL UPDATE. Force the
    status via direct DB write to faithfully reproduce the crash
    scenario — the v0.6.x stuck-chapter incident that motivated this
    Phase couldn't have been caught with a TestClient-only test.
    """
    from app.models.chapter import Chapter

    _, chapter = _seed_book_chapter(client, auth_headers)

    # Simulate the stuck state.
    with session_factory() as session:
        row = session.get(Chapter, chapter["id"])
        row.status = "writing"
        session.commit()

    # Sanity: normal /write would reject this.
    blocked = client.post(
        f"/api/v1/chapters/{chapter['id']}/write",
        headers=auth_headers,
    )
    assert blocked.status_code == 409, "writing-state chapter should reject /write"

    # admin_reset should succeed and unstick.
    rescued = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    assert rescued.status_code == 200
    assert rescued.json()["status"] == "draft_ready"


def test_admin_reset_is_idempotent(client, auth_headers):
    """Reviewer 🟡 #5: a user double-clicking the rescue button should
    not produce two agent_log rows. The second call must be a no-op
    that returns the current ChapterRead without touching updated_at.
    """
    _, chapter = _seed_book_chapter(client, auth_headers)

    # First reset (real transition draft → draft_ready).
    r1 = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    assert r1.status_code == 200
    assert r1.json()["status"] == "draft_ready"
    first_updated_at = r1.json()["updated_at"]

    # Second reset to the same target — should be a no-op.
    r2 = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
        headers=auth_headers,
    )
    assert r2.status_code == 200
    assert r2.json()["status"] == "draft_ready"
    # updated_at must not have moved — proves no DB write happened.
    assert r2.json()["updated_at"] == first_updated_at

    # And only one agent_log row should exist for the actual transition.
    logs = client.get(
        f"/api/v1/admin/logs?chapter_id={chapter['id']}",
        headers=auth_headers,
    ).json()
    reset_logs = [e for e in logs["items"] if e["agent_name"] == "admin_reset"]
    assert len(reset_logs) == 1, f"expected exactly 1 admin_reset log, got {len(reset_logs)}"


def test_admin_reset_requires_auth(client):
    book = client.post(
        "/api/v1/books",
        headers={"Authorization": "Bearer test-token-value"},
        json={"title": "X", "cover_color": "#000000"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers={"Authorization": "Bearer test-token-value"},
        json={"user_prompt": "x"},
    ).json()
    # No auth header.
    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/admin_reset",
    )
    assert response.status_code == 401
