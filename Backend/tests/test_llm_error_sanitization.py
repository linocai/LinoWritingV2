"""Tests for the LLM upstream 4xx body sanitiser (§5.P.1 A).

We need to make sure no credential-looking string leaks from an
upstream error response into the LLMError message (which then flows
into agent_logs + Toast banners + the admin UI).
"""
from __future__ import annotations

from app.llm.openai_compatible import (
    UPSTREAM_BODY_LIMIT,
    _sanitize_error_body,
)


def test_sanitize_redacts_bearer_token():
    body = '{"error": "bad Authorization: Bearer sk-abcdef1234567890"}'
    out = _sanitize_error_body(body)
    assert "sk-abcdef1234567890" not in out
    assert "Bearer" not in out  # Whole "Bearer <token>" group replaced.
    assert "***" in out


def test_sanitize_redacts_authorization_header_form():
    body = 'unauthorized — Authorization: sk-or-veryverysecret echoed'
    out = _sanitize_error_body(body)
    assert "sk-or-veryverysecret" not in out
    assert "***" in out


def test_sanitize_redacts_xai_key():
    body = "invalid key: xai-1234567890abcdef"
    out = _sanitize_error_body(body)
    assert "xai-1234567890abcdef" not in out
    assert "***" in out


def test_sanitize_redacts_openai_style_key():
    body = "request used sk-1234567890abcdefghij"
    out = _sanitize_error_body(body)
    assert "sk-1234567890abcdefghij" not in out
    assert "***" in out


def test_sanitize_truncates_long_body():
    body = "A" * 10_000
    out = _sanitize_error_body(body)
    assert len(out) <= UPSTREAM_BODY_LIMIT + len("...(truncated)")
    assert out.endswith("...(truncated)")


def test_sanitize_redacts_before_truncating():
    """If we truncated first, the trailing redacted-blob might be cut
    in half and leak a partial secret. Order: redact, then truncate."""
    # Construct a body where the secret sits past the truncation limit.
    prefix = "B" * (UPSTREAM_BODY_LIMIT - 20)
    body = prefix + " Bearer sk-supersecretpadding"
    out = _sanitize_error_body(body)
    # Either the bearer is replaced, or (if it got truncated away) it
    # must not appear at all.
    assert "sk-supersecretpadding" not in out


def test_sanitize_passthrough_for_benign_body():
    body = '{"error": {"code": 401, "message": "invalid_request"}}'
    out = _sanitize_error_body(body)
    assert "invalid_request" in out
    assert "***" not in out  # No secrets, no redaction.


def test_sanitize_empty_body():
    assert _sanitize_error_body("") == ""
