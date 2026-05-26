"""v0.8 T-2 (§5.T) — uvicorn access-log secret redaction filter.

We don't actually drive uvicorn here; we exercise the filter directly
against synthetic LogRecord objects and against the shared
``redact_secrets`` helper. This is the same regex set the LLM upstream
error sanitizer uses, so a regression in either location is caught here.
"""
from __future__ import annotations

import logging

from app.middleware.access_log_filter import (
    SecretRedactionFilter,
    UVICORN_ACCESS_LOGGER,
    install_access_log_redaction,
)
from app.services.secret_redaction import redact_secrets


def _make_record(msg: str, args: object = None) -> logging.LogRecord:
    return logging.LogRecord(
        name=UVICORN_ACCESS_LOGGER,
        level=logging.INFO,
        pathname=__file__,
        lineno=0,
        msg=msg,
        args=args,
        exc_info=None,
    )


def test_filter_redacts_bearer_token_in_message():
    """An access log line with ``Bearer …`` literal must be redacted."""
    record = _make_record('127.0.0.1 - "GET /x HTTP/1.1 Bearer eyJabc123def" 200')
    filt = SecretRedactionFilter()
    assert filt.filter(record) is True
    assert "eyJabc123def" not in record.msg
    assert "***" in record.msg


def test_filter_redacts_api_key_in_query_string():
    """``?api_key=sk-abc123def456`` in the request line gets redacted."""
    record = _make_record('127.0.0.1 - "GET /x?api_key=sk-abc123def456 HTTP/1.1" 200')
    filt = SecretRedactionFilter()
    filt.filter(record)
    assert "sk-abc123def456" not in record.msg
    assert "***" in record.msg


def test_filter_passes_through_innocuous_messages():
    """Lines with no secret-shaped tokens are unchanged."""
    original = '127.0.0.1 - "GET /api/v1/health HTTP/1.1" 200 OK'
    record = _make_record(original)
    filt = SecretRedactionFilter()
    filt.filter(record)
    assert record.msg == original


def test_filter_handles_tuple_args():
    """uvicorn's default formatter uses ``args`` for interpolation
    (``msg % args``). Secrets inside args must also be redacted."""
    record = _make_record(
        "%s - %s %s",
        ("127.0.0.1", "GET /x?token=xai-abcd1234efgh HTTP/1.1", "200"),
    )
    filt = SecretRedactionFilter()
    filt.filter(record)
    assert all("xai-abcd1234efgh" not in str(arg) for arg in record.args)
    # The arg containing the secret should now contain ``***``.
    assert any("***" in str(arg) for arg in record.args)


def test_install_is_idempotent():
    """Multiple calls to install_access_log_redaction() must leave
    exactly one filter attached, not stack duplicates."""
    logger = logging.getLogger(UVICORN_ACCESS_LOGGER)
    # Clean slate: drop any pre-existing redaction filter (the lifespan
    # may have added one already through the test client fixture).
    logger.filters = [
        f for f in logger.filters if not isinstance(f, SecretRedactionFilter)
    ]

    install_access_log_redaction()
    install_access_log_redaction()
    install_access_log_redaction()

    redaction_filters = [
        f for f in logger.filters if isinstance(f, SecretRedactionFilter)
    ]
    assert len(redaction_filters) == 1


def test_redact_secrets_covers_all_provider_prefixes():
    """End-to-end check against the shared regex helper — same module
    the LLM error sanitizer uses, so a single test pinning all the
    prefixes is enough."""
    samples = [
        ("sk-abc123def456", "OpenAI"),
        ("sk-ant-abc123def456", "Anthropic"),
        ("sk-or-abc123def456", "OpenRouter"),
        ("sk_live_abc123def456", "OpenAI restricted"),
        ("xai-abc123def456", "xAI"),
        ("AIzaabc123def456", "Google"),
        ("Bearer eyJabc.def.ghi", "Bearer header"),
    ]
    for raw, label in samples:
        assert raw not in redact_secrets(raw), f"{label} not redacted: {raw}"
