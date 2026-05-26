"""Shared secret-redaction regex utilities.

v0.8 T-2 (§5.T): moved out of ``app/llm/openai_compatible.py`` so both the
LLM upstream error sanitizer **and** the uvicorn access-log filter
(``app/middleware/access_log_filter.py``) can share a single source of
truth. Adding a new pattern only needs to happen here once.

The regex list is intentionally short and high-signal — false positives
("``***``" instead of an opaque chunk of error text) are cheap; false
negatives leak keys into agent_log preview rows or access-log lines that
later get tailed / shipped to a log aggregator.
"""
from __future__ import annotations

import re

# Patterns that look like credentials / bearer tokens. Anything matched
# gets replaced with ``***``. Order: explicit ``Bearer``/``Authorization``
# headers first (broadest match), then provider-specific prefixes.
_REDACTION_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"Bearer\s+\S+", re.IGNORECASE),
    re.compile(r"Authorization\s*:\s*\S+", re.IGNORECASE),
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),       # OpenAI default
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"),   # Anthropic native
    re.compile(r"sk-or-[A-Za-z0-9_\-]{8,}"),    # OpenRouter
    re.compile(r"sk_live_[A-Za-z0-9_\-]{8,}"),  # OpenAI restricted
    re.compile(r"xai-[A-Za-z0-9_\-]{8,}"),      # xAI / Grok
    re.compile(r"AIza[A-Za-z0-9_\-]{8,}"),      # Google (Gemini OpenAI-compat)
)


def redact_secrets(text: str) -> str:
    """Apply all redaction patterns to ``text`` and return the sanitised
    result.

    Idempotent: running it twice yields the same string. Empty / None-ish
    inputs short-circuit to ``""``.
    """
    if not text:
        return ""
    redacted = text
    for pattern in _REDACTION_PATTERNS:
        redacted = pattern.sub("***", redacted)
    return redacted
