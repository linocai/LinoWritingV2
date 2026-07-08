"""Tests for v1.3.4 快修 — token usage 观测 (改动三).

Context: ``agent_logs.tokens_in`` / ``tokens_out`` columns (and the
``AgentLogRead`` schema slot exposing them) have existed since an earlier
phase, but nothing ever populated them — ``OpenAICompatibleClient`` never
extracted ``usage`` off an upstream response, and ``log_agent_call`` didn't
even accept the values as parameters. This closes that gap:

  - ``OpenAICompatibleClient.last_usage`` — populated by ``complete`` /
    ``complete_json`` (non-streaming) from the response body's ``usage``
    object, and by ``complete_stream`` from a ``stream_options.include_usage``
    chunk (typically the final one, which may carry an EMPTY ``choices``
    list alongside the usage object — must not raise).
  - ``app.services.agent_logging.llm_usage_kwargs`` — the small adapter
    routers/write_jobs use to turn ``llm.last_usage`` into
    ``log_agent_call(**...)`` kwargs, tolerating clients that don't expose
    ``last_usage`` at all (test mocks) or leave it ``None``.
  - ``log_agent_call`` itself persisting ``tokens_in``/``tokens_out`` onto
    the ``AgentLog`` row.

``_FakeHttpxStream`` / ``_provider_key`` are the shared helpers from
``test_sse_cancel.py``.
"""
from __future__ import annotations

from unittest.mock import patch

from app.models.agent_log import AgentLog
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models.provider_key import ProviderKey
from app.services.agent_logging import llm_usage_kwargs, log_agent_call
from tests.test_sse_cancel import _FakeHttpxStream, _provider_key


class _FakeJsonResponse:
    status_code = 200

    def __init__(self, body: dict) -> None:
        self._body = body

    def json(self) -> dict:
        return self._body


def test_complete_records_usage_from_response() -> None:
    client = OpenAICompatibleClient(_provider_key())
    body = {
        "choices": [{"message": {"content": "正文"}}],
        "usage": {"prompt_tokens": 120, "completion_tokens": 45, "total_tokens": 165},
    }
    with patch("app.llm.openai_compatible.httpx.post", return_value=_FakeJsonResponse(body)):
        result = client.complete(system="s", user="u")

    assert result == "正文"
    assert client.last_usage == {"prompt_tokens": 120, "completion_tokens": 45}


def test_complete_json_records_usage_from_response() -> None:
    client = OpenAICompatibleClient(_provider_key())
    body = {
        "choices": [{"message": {"content": '{"a": 1}'}}],
        "usage": {"prompt_tokens": 80, "completion_tokens": 10},
    }
    with patch("app.llm.openai_compatible.httpx.post", return_value=_FakeJsonResponse(body)):
        result = client.complete_json(system="s", user="u", schema={})

    assert result == {"a": 1}
    assert client.last_usage == {"prompt_tokens": 80, "completion_tokens": 10}


def test_complete_last_usage_is_none_when_provider_omits_usage() -> None:
    """Provider doesn't report usage at all — must degrade to None, never raise."""
    client = OpenAICompatibleClient(_provider_key())
    body = {"choices": [{"message": {"content": "正文"}}]}  # no "usage" key
    with patch("app.llm.openai_compatible.httpx.post", return_value=_FakeJsonResponse(body)):
        client.complete(system="s", user="u")

    assert client.last_usage is None


def test_complete_stream_requests_usage_via_stream_options() -> None:
    """`_payload` must ask compatible upstreams for a final usage chunk."""
    client = OpenAICompatibleClient(_provider_key())
    fake = _FakeHttpxStream(['data: {"choices":[{"delta":{"content":"正文"}}]}', "data: [DONE]"])
    captured: dict = {}

    def _capture_stream(method, url, *, headers, json, timeout):
        captured.update(json)
        return fake

    with patch("app.llm.openai_compatible.httpx.stream", side_effect=_capture_stream):
        list(client.complete_stream(system="s", user="u"))

    assert captured.get("stream_options") == {"include_usage": True}


def test_complete_stream_records_usage_from_trailing_empty_choices_chunk() -> None:
    """The usage-bearing chunk (per OpenAI's `stream_options.include_usage`
    contract) typically has an EMPTY `choices` list — parsing it must not
    raise, and it must still populate `last_usage`."""
    client = OpenAICompatibleClient(_provider_key())
    fake = _FakeHttpxStream(
        [
            'data: {"choices":[{"delta":{"content":"正文"}}]}',
            'data: {"choices":[],"usage":{"prompt_tokens":300,"completion_tokens":120}}',
            "data: [DONE]",
        ]
    )
    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        chunks = list(client.complete_stream(system="s", user="u"))

    assert len(chunks) == 1  # the empty-choices usage chunk yields no StreamChunk
    assert chunks[0].text == "正文"
    assert client.last_usage == {"prompt_tokens": 300, "completion_tokens": 120}


def test_complete_stream_last_usage_none_when_provider_never_sends_usage_chunk() -> None:
    client = OpenAICompatibleClient(_provider_key())
    fake = _FakeHttpxStream(['data: {"choices":[{"delta":{"content":"正文"}}]}', "data: [DONE]"])
    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        list(client.complete_stream(system="s", user="u"))

    assert client.last_usage is None


def test_complete_stream_resets_last_usage_between_calls() -> None:
    """A stale usage value from an earlier call on the SAME client instance
    must not leak forward into a later call whose provider sends none."""
    client = OpenAICompatibleClient(_provider_key())
    body = {"choices": [{"message": {"content": "x"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
    with patch("app.llm.openai_compatible.httpx.post", return_value=_FakeJsonResponse(body)):
        client.complete(system="s", user="u")
    assert client.last_usage is not None

    fake = _FakeHttpxStream(['data: {"choices":[{"delta":{"content":"正文"}}]}', "data: [DONE]"])
    with patch("app.llm.openai_compatible.httpx.stream", return_value=fake):
        list(client.complete_stream(system="s", user="u"))

    assert client.last_usage is None


def test_llm_usage_kwargs_reads_last_usage() -> None:
    class _Client:
        last_usage = {"prompt_tokens": 50, "completion_tokens": 20}

    assert llm_usage_kwargs(_Client()) == {"tokens_in": 50, "tokens_out": 20}


def test_llm_usage_kwargs_tolerates_missing_or_none_last_usage() -> None:
    class _NoUsageAttr:
        pass

    class _NoneUsage:
        last_usage = None

    assert llm_usage_kwargs(_NoUsageAttr()) == {"tokens_in": None, "tokens_out": None}
    assert llm_usage_kwargs(_NoneUsage()) == {"tokens_in": None, "tokens_out": None}


def test_log_agent_call_persists_tokens(db_session) -> None:
    log_agent_call(
        db_session,
        chapter_id=None,
        agent_name="writer",
        input_data={"x": 1},
        output_data="正文",
        tokens_in=200,
        tokens_out=90,
    )
    db_session.commit()
    row = db_session.query(AgentLog).order_by(AgentLog.created_at.desc()).first()
    assert row is not None
    assert row.tokens_in == 200
    assert row.tokens_out == 90


def test_log_agent_call_defaults_tokens_to_none(db_session) -> None:
    """Callers that don't pass tokens_in/out (e.g. admin_reset, which never
    touches an LLM) must not error, and the row stores NULL."""
    log_agent_call(db_session, chapter_id=None, agent_name="admin_reset", input_data={})
    db_session.commit()
    row = db_session.query(AgentLog).order_by(AgentLog.created_at.desc()).first()
    assert row is not None
    assert row.tokens_in is None
    assert row.tokens_out is None
