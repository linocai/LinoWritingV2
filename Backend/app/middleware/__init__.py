"""v0.8 T-2 (§5.T) — security middleware.

Three small middlewares share this package:

- :mod:`app.middleware.rate_limit` — per-token rate limiting (slowapi)
- :mod:`app.middleware.security_headers` — HSTS + nosniff + frame-deny
- :mod:`app.middleware.access_log_filter` — uvicorn access-log secret
  redaction (regex shared with the LLM error sanitizer)
"""
