"""OpenAI-compatible LLM client.

v0.6 unifies all LLM access behind the OpenAI ``/chat/completions`` protocol.
Any endpoint that speaks it (xAI / OpenAI / OpenRouter / DeepSeek / vLLM /
Together / Groq / …) can be addressed by configuring a :class:`ProviderKey`
row with the matching ``base_url`` and ``model_name``. This module deliberately
contains no provider-specific branching — the only differences are the URL,
auth token, and the model string passed in the payload.
"""
from __future__ import annotations

import json
import re
import time
from collections.abc import Iterator
from threading import Event
from typing import Any

import httpx

from app.llm.errors import LLMError
from app.models.provider_key import ProviderKey

# Maximum characters of an upstream 4xx response body to surface in error
# messages / agent_log rows. Anything longer is truncated. See §5.P.1 A.
UPSTREAM_BODY_LIMIT = 256

# Regex patterns that look like credentials / bearer tokens. Anything matched
# gets replaced with ``***`` before the body is embedded in an LLMError. We
# intentionally keep this list short and high-signal: false positives are
# cheap (a "***" instead of opaque text in an error message), false negatives
# leak keys into agent_log preview rows that the frontend later renders.
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


def _sanitize_error_body(body: str) -> str:
    """Redact obvious secrets, then truncate.

    Order matters: redact first, truncate second. If we truncated first the
    final ``***`` substitution might land in the cut-off region and leak a
    half-key. After redaction every secret-looking blob is replaced so the
    truncated tail is safe.
    """

    if not body:
        return ""
    redacted = body
    for pattern in _REDACTION_PATTERNS:
        redacted = pattern.sub("***", redacted)
    if len(redacted) > UPSTREAM_BODY_LIMIT:
        redacted = redacted[:UPSTREAM_BODY_LIMIT] + "...(truncated)"
    return redacted


class OpenAICompatibleClient:
    def __init__(self, provider_key: ProviderKey) -> None:
        self.api_key = provider_key.api_key
        self.base_url = (provider_key.base_url or "").rstrip("/")
        self.model_name = provider_key.model_name

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        payload = self._payload(system=system, user=user, stream=False, **kwargs)
        data = self._post_json(payload, timeout=kwargs.get("timeout", 60))
        return _extract_content(data)

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        schema_text = json.dumps(schema, ensure_ascii=False)
        system_with_schema = (
            f"{system}\n\n"
            "你必须只返回一个合法 JSON object，不要使用 Markdown 代码块。\n"
            f"JSON schema 参考：{schema_text}"
        )
        payload = self._payload(
            system=system_with_schema,
            user=user,
            response_format={"type": "json_object"},
            stream=False,
            **kwargs,
        )
        data = self._post_json(payload, timeout=kwargs.get("timeout", 60))
        content = _extract_content(data)
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError as exc:
            raise LLMError(f"LLM returned invalid JSON: {exc}", retryable=False) from exc
        if not isinstance(parsed, dict):
            raise LLMError("LLM JSON response was not an object", retryable=False)
        return parsed

    def complete_stream(
        self,
        *,
        system: str,
        user: str,
        cancel_event: Event | None = None,
        **kwargs: Any,
    ) -> Iterator[str]:
        # cancel_event is plumbed all the way down to the httpx.iter_lines()
        # loop so we can stop pulling tokens from the upstream as soon as the
        # client disconnects. See §5.P.1 D.
        payload = self._payload(system=system, user=user, stream=True, **kwargs)
        response = self._stream(
            payload,
            timeout=kwargs.get("timeout", 180),
            cancel_event=cancel_event,
        )
        yield from response

    def _payload(self, *, system: str, user: str, stream: bool, **kwargs: Any) -> dict[str, Any]:
        model = kwargs.get("model") or self.model_name
        payload: dict[str, Any] = {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "stream": stream,
        }
        for key in ("temperature", "max_tokens", "response_format"):
            if key in kwargs and kwargs[key] is not None:
                payload[key] = kwargs[key]
        return payload

    def _headers(self) -> dict[str, str]:
        if not self.api_key:
            raise LLMError("LLM api_key is not configured", retryable=False)
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def _post_json(self, payload: dict[str, Any], *, timeout: int) -> dict[str, Any]:
        url = f"{self.base_url}/chat/completions"
        for attempt in range(3):
            try:
                response = httpx.post(url, headers=self._headers(), json=payload, timeout=timeout)
                if response.status_code >= 500:
                    raise LLMError(f"LLM upstream server error: {response.status_code}", retryable=True)
                if response.status_code >= 400:
                    body = response.read().decode("utf-8", errors="replace")
                    safe_body = _sanitize_error_body(body)
                    raise LLMError(
                        f"LLM upstream request failed: {response.status_code} {safe_body}",
                        retryable=False,
                    )
                return response.json()
            except (httpx.TimeoutException, httpx.TransportError, LLMError) as exc:
                retryable = getattr(exc, "retryable", True)
                if attempt == 2 or not retryable:
                    if isinstance(exc, LLMError):
                        raise
                    raise LLMError(str(exc), retryable=True) from exc
                time.sleep(2**attempt)
        raise LLMError("LLM upstream request failed", retryable=True)

    def _stream(
        self,
        payload: dict[str, Any],
        *,
        timeout: int,
        cancel_event: Event | None = None,
    ) -> Iterator[str]:
        url = f"{self.base_url}/chat/completions"
        try:
            with httpx.stream(
                "POST",
                url,
                headers=self._headers(),
                json=payload,
                timeout=timeout,
            ) as response:
                if response.status_code >= 500:
                    raise LLMError(f"LLM upstream server error: {response.status_code}", retryable=True)
                if response.status_code >= 400:
                    # Drain (with sanitisation) before raising so the body
                    # error message contains useful diagnostics minus secrets.
                    safe_body = _sanitize_error_body(response.read().decode("utf-8", errors="replace"))
                    raise LLMError(
                        f"LLM upstream request failed: {response.status_code} {safe_body}",
                        retryable=False,
                    )
                # Pre-loop cancel check — if the caller already cancelled
                # before we even got past the response headers, bail out
                # immediately. Closes the httpx response on context exit.
                if cancel_event is not None and cancel_event.is_set():
                    return
                for line in response.iter_lines():
                    # Check cancel *every* iteration, before doing any work,
                    # so a fast cancel can't burn another token by sneaking
                    # past while we json.loads / yield. The with-block exit
                    # is what actually closes the upstream socket.
                    if cancel_event is not None and cancel_event.is_set():
                        return
                    if not line or line.startswith(":"):
                        continue
                    if not line.startswith("data:"):
                        continue
                    data = line.removeprefix("data:").strip()
                    if data == "[DONE]":
                        break
                    chunk = json.loads(data)
                    # Some OpenAI-compatible providers (Grok / OpenAI itself
                    # when usage stats are enabled, DeepSeek for token-limit
                    # edge cases, ...) emit metadata-only frames with an
                    # empty `choices` list. They aren't errors — just skip.
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    token = delta.get("content")
                    if token:
                        yield token
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            raise LLMError(str(exc), retryable=True) from exc


def _extract_content(data: dict[str, Any]) -> str:
    """Pull the assistant message out of a non-streaming /chat/completions
    response without exploding on edge cases.

    Defends against:
    - `{"choices": []}` — empty list (some providers return this when the
      model refuses, hits a safety filter, or runs out of tokens before
      producing any content).
    - `{"choices": [{"message": null}]}` or missing keys — partial
      responses from misbehaving compat layers.
    Both surface as a retryable LLMError so the caller's retry / error
    banner path runs instead of a raw IndexError / KeyError 500.
    """
    choices = data.get("choices") or []
    if not choices:
        finish = data.get("error") or data.get("finish_reason") or "no choices returned"
        raise LLMError(f"LLM returned no choices ({finish})", retryable=True)
    message = choices[0].get("message") or {}
    content = message.get("content")
    if content is None:
        raise LLMError("LLM response missing message.content", retryable=True)
    return content
