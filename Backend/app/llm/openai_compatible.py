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
import time
from collections.abc import Iterator
from typing import Any

import httpx

from app.llm.errors import LLMError
from app.models.provider_key import ProviderKey


class OpenAICompatibleClient:
    def __init__(self, provider_key: ProviderKey) -> None:
        self.api_key = provider_key.api_key
        self.base_url = (provider_key.base_url or "").rstrip("/")
        self.model_name = provider_key.model_name

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        payload = self._payload(system=system, user=user, stream=False, **kwargs)
        data = self._post_json(payload, timeout=kwargs.get("timeout", 60))
        return data["choices"][0]["message"]["content"]

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
        content = data["choices"][0]["message"]["content"]
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError as exc:
            raise LLMError(f"LLM returned invalid JSON: {exc}", retryable=False) from exc
        if not isinstance(parsed, dict):
            raise LLMError("LLM JSON response was not an object", retryable=False)
        return parsed

    def complete_stream(self, *, system: str, user: str, **kwargs: Any) -> Iterator[str]:
        payload = self._payload(system=system, user=user, stream=True, **kwargs)
        response = self._stream(payload, timeout=kwargs.get("timeout", 180))
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
                    raise LLMError(f"LLM upstream request failed: {response.status_code} {body}", retryable=False)
                return response.json()
            except (httpx.TimeoutException, httpx.TransportError, LLMError) as exc:
                retryable = getattr(exc, "retryable", True)
                if attempt == 2 or not retryable:
                    if isinstance(exc, LLMError):
                        raise
                    raise LLMError(str(exc), retryable=True) from exc
                time.sleep(2**attempt)
        raise LLMError("LLM upstream request failed", retryable=True)

    def _stream(self, payload: dict[str, Any], *, timeout: int) -> Iterator[str]:
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
                    raise LLMError(
                        f"LLM upstream request failed: {response.status_code} {response.text}",
                        retryable=False,
                    )
                for line in response.iter_lines():
                    if not line or line.startswith(":"):
                        continue
                    if not line.startswith("data:"):
                        continue
                    data = line.removeprefix("data:").strip()
                    if data == "[DONE]":
                        break
                    chunk = json.loads(data)
                    token = chunk["choices"][0].get("delta", {}).get("content")
                    if token:
                        yield token
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            raise LLMError(str(exc), retryable=True) from exc
