"""v0.8 T-2 (§5.T) — SecurityHeadersMiddleware behaviour.

Coverage:

- HTTPS request (simulated via ``X-Forwarded-Proto: https``) gets HSTS.
- Plain HTTP request does *not* get HSTS (we deliberately gate it on
  scheme so a misconfigured reverse proxy doesn't lie about TLS).
- Both branches always carry ``X-Content-Type-Options: nosniff`` and
  ``X-Frame-Options: DENY``.
- The HSTS value matches §5.T.5: 1 year, **no** ``includeSubDomains``.
"""
from __future__ import annotations


def test_hsts_present_on_https(client, auth_headers):
    """When the reverse proxy forwards ``X-Forwarded-Proto: https``
    (the §5.S.3 Nginx site sets this), the response carries HSTS."""
    headers = {**auth_headers, "X-Forwarded-Proto": "https"}
    response = client.get("/api/v1/health", headers=headers)
    assert response.status_code == 200
    hsts = response.headers.get("Strict-Transport-Security")
    assert hsts is not None, "HSTS header missing on HTTPS-forwarded request"
    assert hsts == "max-age=31536000"
    # Explicit §5.T.5 decision: we do NOT enable includeSubDomains
    # because the apex domain has unrelated sibling subdomains we
    # mustn't force-pin to HTTPS.
    assert "includeSubDomains" not in hsts


def test_hsts_absent_on_http(client, auth_headers):
    """Plain HTTP request (no X-Forwarded-Proto, TestClient default
    base is http://) must NOT carry HSTS. Browsers ignore HSTS on
    http:// anyway, but emitting it would be spec-violating and
    confusing in operator logs."""
    response = client.get("/api/v1/health", headers=auth_headers)
    assert response.status_code == 200
    assert "Strict-Transport-Security" not in response.headers


def test_static_security_headers_always_present(client, auth_headers):
    """nosniff + frame-deny are scheme-independent — every response
    gets them, HTTPS or not."""
    response = client.get("/api/v1/health", headers=auth_headers)
    assert response.status_code == 200
    assert response.headers.get("X-Content-Type-Options") == "nosniff"
    assert response.headers.get("X-Frame-Options") == "DENY"


def test_security_headers_on_error_response(client):
    """A 401 response from the auth dependency must still carry the
    static headers — the middleware sits outside the dependency stack
    so it runs regardless of route outcome."""
    response = client.get("/api/v1/health")  # no auth
    assert response.status_code == 401
    assert response.headers.get("X-Content-Type-Options") == "nosniff"
    assert response.headers.get("X-Frame-Options") == "DENY"
