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
import logging
import time
from collections.abc import Iterator
from threading import Event
from typing import Any

import httpx

from app.llm.base import StreamChunk
from app.llm.errors import LLMError
from app.models.provider_key import ProviderKey
from app.services.encryption import decrypt_api_key
from app.services.secret_redaction import redact_secrets

logger = logging.getLogger(__name__)

# Maximum characters of an upstream 4xx response body to surface in error
# messages / agent_log rows. Anything longer is truncated. See §5.P.1 A.
UPSTREAM_BODY_LIMIT = 256

# v1.3.1 (KK) P3: default request timeout for the two non-streaming call
# shapes (`complete` / `complete_json`), covering extract/expand/finalize/
# import/parse. Was 60s — too tight for thinking-capable models on slow
# relays; callers never pass an explicit `timeout` kwarg today, so bumping
# this one default covers all of them in one place. The streaming path
# (`complete_stream`) is untouched — it already runs on a separate
# per-phase `httpx.Timeout` (read=180) unrelated to this constant.
DEFAULT_NON_STREAM_TIMEOUT_SECONDS = 300


def _sanitize_error_body(body: str) -> str:
    """Redact obvious secrets, then truncate.

    Order matters: redact first, truncate second. If we truncated first the
    final ``***`` substitution might land in the cut-off region and leak a
    half-key. After redaction every secret-looking blob is replaced so the
    truncated tail is safe.

    v0.8 T-2 (§5.T): regex list lives in
    :mod:`app.services.secret_redaction` so the uvicorn access-log filter
    can share the same set without copy-pasting patterns that would drift.
    """

    if not body:
        return ""
    redacted = redact_secrets(body)
    if len(redacted) > UPSTREAM_BODY_LIMIT:
        redacted = redacted[:UPSTREAM_BODY_LIMIT] + "...(truncated)"
    return redacted


class OpenAICompatibleClient:
    def __init__(self, provider_key: ProviderKey) -> None:
        # v0.8 T-1 (§5.T): on-disk ``provider_key.api_key`` is Fernet
        # ciphertext. Decrypt once here so every outbound LLM call uses the
        # plaintext token in the ``Authorization: Bearer ...`` header.
        # ``decrypt_api_key`` falls back to returning the input unchanged for
        # pre-migration plaintext rows; this is the read-side dual that lets
        # an in-flight upgrade keep working until the Alembic data migration
        # rewrites those rows.
        self.api_key = decrypt_api_key(provider_key.api_key)
        self.base_url = (provider_key.base_url or "").rstrip("/")
        self.model_name = provider_key.model_name
        # v1.3.4 快修 — 观测: token usage of the MOST RECENT call this client
        # instance made (``{"prompt_tokens": int|None, "completion_tokens":
        # int|None}``, or ``None`` if the upstream never reported usage / no
        # call has completed yet). Each per-request router/worker constructs
        # a fresh client (see ``llm/factory.py``), so there is no cross-request
        # leakage — this is purely "what did the call I just made cost".
        # Callers read it via ``app.services.agent_logging.llm_usage_kwargs``.
        self.last_usage: dict[str, int | None] | None = None

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        payload = self._payload(system=system, user=user, stream=False, **kwargs)
        data = self._post_json(payload, timeout=kwargs.get("timeout", DEFAULT_NON_STREAM_TIMEOUT_SECONDS))
        self.last_usage = _extract_usage(data)
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
        data = self._post_json(payload, timeout=kwargs.get("timeout", DEFAULT_NON_STREAM_TIMEOUT_SECONDS))
        self.last_usage = _extract_usage(data)
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
    ) -> Iterator[StreamChunk]:
        # cancel_event is plumbed all the way down to the httpx.iter_lines()
        # loop so we can stop pulling tokens from the upstream as soon as the
        # client disconnects. See §5.P.1 D.
        #
        # v1.2.0 (HH) P6: the caller's ``timeout`` kwarg used to become a
        # plain ``httpx.Timeout(N)`` (that int applies to connect/read/write
        # /pool *all four* phases), so a slow relay's inter-chunk gap was
        # bound by the same 180s that was meant as an overall budget. An
        # explicit ``httpx.Timeout(connect=…, read=…, write=…, pool=…)``
        # gives each phase its own bound — ``read`` (inter-chunk gap) keeps
        # the caller's value (Writer passes 180, unchanged from before —
        # author-approved, not tightened to 120 so slow relays' block
        # intervals aren't misfired on); connect/write/pool get short fixed
        # bounds since they only matter once at the start of the request.
        # Critically, httpx has **no separate overall-duration timeout** —
        # as long as each individual read keeps arriving inside `read`
        # seconds, the stream can run indefinitely, which is exactly the
        # "no total time limit, only a per-chunk stall detector" contract
        # P6 wants for multi-hour slow-relay chapters.
        payload = self._payload(system=system, user=user, stream=True, **kwargs)
        # v1.3.4 快修 — 观测: reset before this call so a stale value from an
        # earlier call on this same client instance can't be mistaken for
        # this stream's usage if the upstream never sends a usage chunk.
        self.last_usage = None
        read_timeout = kwargs.get("timeout", 180)
        timeout = httpx.Timeout(connect=15, read=read_timeout, write=30, pool=15)
        response = self._stream(
            payload,
            timeout=timeout,
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
        if stream:
            # v1.3.4 快修 — 观测: ask OpenAI-compatible upstreams for a final
            # usage-bearing chunk on the streaming path too (previously only
            # `complete`/`complete_json` exposed usage). Providers that don't
            # recognise this field simply ignore it — never an error.
            payload["stream_options"] = {"include_usage": True}
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
        timeout: int | httpx.Timeout,
        cancel_event: Event | None = None,
    ) -> Iterator[StreamChunk]:
        url = f"{self.base_url}/chat/completions"
        # v1.4.0 (MM) P2 (🟡8) — stream_options defence. Some OpenAI-compatible
        # relays don't recognise ``stream_options`` (we send
        # ``{"include_usage": True}`` on every stream for token观测) and reject
        # the request with a 400 BEFORE any chunk is yielded — so dropping the
        # field and retrying ONCE is safe/idempotent (nothing was streamed yet).
        # This is a deliberate, no-diff-check retry: a 400 whose payload carried
        # stream_options → strip it, log the first sanitised body once, retry.
        # A second failure (of any kind) raises that second error.
        retried_without_stream_options = False
        try:
            while True:
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
                        if (
                            response.status_code == 400
                            and "stream_options" in payload
                            and not retried_without_stream_options
                        ):
                            logger.warning(
                                "LLM upstream 400 with stream_options; retrying once without it. body=%s",
                                safe_body,
                            )
                            payload = {k: v for k, v in payload.items() if k != "stream_options"}
                            retried_without_stream_options = True
                            self.last_usage = None  # no usage可得 from a failed / options-less call
                            continue  # re-enter the while-loop with the stripped payload
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
                        # v1.3.4 快修 — 观测: with `stream_options.include_usage`
                        # set (see `_payload`), a usage-bearing chunk (typically
                        # the LAST one) carries token counts alongside — or
                        # instead of — an empty `choices` list. Extract it BEFORE
                        # the `choices` early-continue below so it isn't skipped;
                        # only overwrite `last_usage` when this particular chunk
                        # actually has a `usage` object (an interim chunk without
                        # one must not clobber a usage value a later chunk sets).
                        usage = _extract_usage(chunk)
                        if usage is not None:
                            self.last_usage = usage
                        # Some OpenAI-compatible providers (Grok / OpenAI itself
                        # when usage stats are enabled, DeepSeek for token-limit
                        # edge cases, ...) emit metadata-only frames with an
                        # empty `choices` list. They aren't errors — just skip.
                        choices = chunk.get("choices") or []
                        if not choices:
                            continue
                        delta = choices[0].get("delta") or {}
                        # v1.2.0 (HH) P7: reasoning-capable upstreams (DeepSeek-R1
                        # style) put chain-of-thought deltas in a separate
                        # `reasoning_content` field alongside (or instead of, for
                        # that particular chunk) the final-answer `content`
                        # field. Forward both as distinctly-tagged StreamChunks —
                        # `thinking` chunks are a process indicator only and must
                        # never be mistaken for draft prose downstream.
                        reasoning = delta.get("reasoning_content")
                        if reasoning:
                            yield StreamChunk(kind="thinking", text=reasoning)
                        token = delta.get("content")
                        if token:
                            yield StreamChunk(kind="token", text=token)
                    # SSE stream ended ([DONE] or exhausted) — done, don't retry.
                    return
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            raise LLMError(str(exc), retryable=True) from exc


def _extract_usage(data: dict[str, Any]) -> dict[str, int | None] | None:
    """Pull ``{"prompt_tokens", "completion_tokens"}`` out of a
    ``/chat/completions`` response/chunk's optional ``usage`` object.

    v1.3.4 快修 — 观测: returns ``None`` when ``usage`` is absent or not an
    object (provider doesn't report usage, or this is an interim streaming
    chunk) — callers (``complete``/``complete_json``/``_stream``) treat that
    as "no usage to record for this call", never an error.
    """
    usage = data.get("usage")
    if not isinstance(usage, dict):
        return None
    return {
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
    }


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
