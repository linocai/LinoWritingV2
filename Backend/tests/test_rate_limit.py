"""v0.8 T-2 (§5.T) — rate limit middleware behaviour.

Coverage:

- Hitting a write endpoint past its 30/minute budget returns 429 with
  the AppError envelope, a ``Retry-After`` header, and a Chinese message.
- Per-token isolation: two distinct Bearer tokens each get their own
  bucket. (We can't actually authorise as two different tokens because
  ``require_bearer_token`` only accepts the configured one — but the
  rate-limit middleware runs *before* auth, so we can still verify
  bucketing by counting 401-vs-429 outcomes.)
- Read endpoints get the 600/minute budget — 31 consecutive 200s.
- ``reset_limiter()`` clears all buckets (used by the ``client`` fixture).
"""
from __future__ import annotations

from tests.conftest import TEST_TOKEN


def _create_chapter(client, auth_headers):
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "速率测试", "cover_color": "#222"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "ch1", "user_prompt": "rate-limit chapter"},
    ).json()
    return chapter


def test_write_rate_limit_hit_returns_429(client, auth_headers):
    """31 consecutive POST /chapters/{id}/expand calls — the 31st must
    fail with our standard 429 AppError envelope."""
    chapter = _create_chapter(client, auth_headers)

    # First 30 calls fit in the 30/minute budget. We don't care about
    # their status — the endpoint will likely 200 / 409 depending on
    # chapter state, but it stays *below* 429. We only care that the
    # 31st gets the 429.
    for _ in range(30):
        client.post(
            f"/api/v1/chapters/{chapter['id']}/expand",
            headers=auth_headers,
        )

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand",
        headers=auth_headers,
    )
    assert response.status_code == 429
    assert response.headers.get("Retry-After") == "60"

    body = response.json()
    assert body["error"]["kind"] == "rate_limited"
    assert body["error"]["message"] == "请求过于频繁，请稍候再试"
    assert body["error"]["retryable"] is True
    assert body["error"]["details"]["code"] == "rate_limited"
    assert body["error"]["details"]["retry_after_seconds"] == 60


def test_write_rate_limit_per_token_isolated(client):
    """Token-A burning through its budget must not affect token-B.

    Both tokens hit the auth check first (only ``TEST_TOKEN`` is valid),
    so the route returns 401 — but the rate limit middleware sits
    *before* auth and consumes a slot for each Bearer token it sees.
    We verify isolation by exhausting token-A's bucket and observing
    that token-B can still make its 30 calls without seeing 429.
    """
    headers_a = {"Authorization": "Bearer attacker-token-a"}
    headers_b = {"Authorization": "Bearer attacker-token-b"}

    # Path is a write endpoint — the synthetic chapter id is fine; the
    # auth check fires before any DB lookup. We just need a route that
    # matches the write allowlist.
    path = "/api/v1/chapters/synthetic-id/expand"

    # Token-A: 30 calls fit, the 31st gets 429.
    for _ in range(30):
        r = client.post(path, headers=headers_a)
        assert r.status_code != 429, "token-A blew budget early"
    blocked = client.post(path, headers=headers_a)
    assert blocked.status_code == 429

    # Token-B: 30 fresh calls — must never hit 429, proving its bucket
    # is independent of token-A's.
    for index in range(30):
        r = client.post(path, headers=headers_b)
        assert r.status_code != 429, (
            f"token-B saw 429 at call {index} — buckets are bleeding"
        )


def test_write_rate_limit_appliesTo_characterParseEndpoint(client, auth_headers):
    """v1.3.0 (II) P2 — POST /books/{id}/characters/parse is LLM-spending
    and must share the tight 30/minute budget, not the 600/minute default.
    We don't care about the actual response status (likely 502 with no
    ProviderKey configured) — only that the 31st call gets 429 first."""
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "速率测试-角色解析"},
    ).json()
    path = f"/api/v1/books/{book['id']}/characters/parse"

    for _ in range(30):
        client.post(path, headers=auth_headers, json={"raw_text": "占位文本"})

    response = client.post(path, headers=auth_headers, json={"raw_text": "占位文本"})
    assert response.status_code == 429
    assert response.headers.get("Retry-After") == "60"


def test_write_rate_limit_appliesTo_reviseEndpoint(client, auth_headers):
    """v1.4.0 (MM) P2 (🔵11) — POST /chapters/{id}/revise is LLM-spending and
    must share the tight 30/minute budget. We don't care about the actual
    per-call status (409 for a non-draft_ready chapter) — only that the 31st
    call trips 429 first, proving it's on the write allowlist not the 600/min
    default."""
    chapter = _create_chapter(client, auth_headers)
    path = f"/api/v1/chapters/{chapter['id']}/revise"

    for _ in range(30):
        client.post(path, headers=auth_headers)

    response = client.post(path, headers=auth_headers)
    assert response.status_code == 429
    assert response.headers.get("Retry-After") == "60"


def test_read_rate_limit_higher(client, auth_headers):
    """GET /chapters/{id} sits on the 600/minute default budget — 31
    consecutive reads must all succeed (or 404 for synthetic id, but
    never 429)."""
    chapter = _create_chapter(client, auth_headers)
    for index in range(31):
        r = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers)
        assert r.status_code != 429, f"read endpoint hit 429 at call {index}"
        # First 30 + the 31st are all happy 200s.
        assert r.status_code == 200


def test_rate_limit_resets_via_helper(client, auth_headers):
    """Sanity: the ``client`` fixture calls ``reset_limiter()`` at
    setup, so a fresh fixture starts with a fresh budget. Drive the
    write endpoint up to 30 hits, then assert the fixture-managed
    reset works by reading the limiter state directly."""
    chapter = _create_chapter(client, auth_headers)
    for _ in range(30):
        client.post(
            f"/api/v1/chapters/{chapter['id']}/expand",
            headers=auth_headers,
        )

    # Manually reset and re-test: the 31st must now succeed (not 429).
    from app.middleware.rate_limit import reset_limiter

    reset_limiter()
    after_reset = client.post(
        f"/api/v1/chapters/{chapter['id']}/expand",
        headers=auth_headers,
    )
    assert after_reset.status_code != 429
