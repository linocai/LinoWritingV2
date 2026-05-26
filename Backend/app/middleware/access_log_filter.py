"""v0.8 T-2 (§5.T): uvicorn access-log secret redaction.

Mounts a :class:`logging.Filter` on the ``uvicorn.access`` logger that
runs every record's ``msg`` / ``args`` through the same regex set as
:mod:`app.services.secret_redaction` (which the LLM upstream error
sanitizer also uses).

Why: uvicorn's default access-log line format is
``%(client_addr)s - "%(request_line)s" %(status_code)s`` — the request
line includes the path *and query string*. If a caller (typo, debug
script, leaked URL in a chat) ever sends a ``?api_key=sk-…`` or
``Bearer …`` literal in the query, that secret would otherwise land in
the operator's syslog / journalctl / docker logs verbatim. With this
filter mounted, the secret is replaced with ``***`` before the line is
formatted.

Mount timing: uvicorn creates the ``uvicorn.access`` logger lazily on
the first request. We add the filter from the FastAPI ``lifespan``
``startup`` step, which runs *after* uvicorn has configured its loggers
but *before* any request is served — exactly the window we want.
"""
from __future__ import annotations

import logging

from app.services.secret_redaction import redact_secrets

UVICORN_ACCESS_LOGGER = "uvicorn.access"


class SecretRedactionFilter(logging.Filter):
    """Apply :func:`redact_secrets` to a log record's rendered message.

    Filters operate on the record *before* the formatter runs. We mutate
    ``record.msg`` and ``record.args`` in place. Returning True keeps the
    record; returning False would drop it (we always keep — we just
    redact).
    """

    def filter(self, record: logging.LogRecord) -> bool:  # noqa: D401 - logging API
        # The access-log format string is the record's ``msg``; the
        # interpolated values (client addr, request line, status) live in
        # ``record.args``. Both can contain secrets in principle — the
        # request line definitely will if the caller put one in the URL —
        # so we redact each separately.
        if isinstance(record.msg, str):
            record.msg = redact_secrets(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                redact_secrets(arg) if isinstance(arg, str) else arg
                for arg in record.args
            )
        elif isinstance(record.args, dict):
            record.args = {
                key: (redact_secrets(value) if isinstance(value, str) else value)
                for key, value in record.args.items()
            }
        return True


def install_access_log_redaction() -> None:
    """Idempotently attach the redaction filter to ``uvicorn.access``.

    Safe to call multiple times — we check for an existing filter of the
    same class on the logger first. This matters because the FastAPI
    lifespan is invoked on every ``TestClient(app)`` context entry; in a
    test suite that re-uses the app object across hundreds of tests we
    don't want to stack hundreds of filters on the same logger.
    """
    logger = logging.getLogger(UVICORN_ACCESS_LOGGER)
    for existing in logger.filters:
        if isinstance(existing, SecretRedactionFilter):
            return
    logger.addFilter(SecretRedactionFilter())
