"""v1.4.0 (MM) P2 — POST /chapters/{id}/revise (standalone revision endpoint).

Covers the endpoint contract:
  - draft_ready pre-condition (non-state → 409 invalid-action);
  - live-job mutual exclusion (a reserved write/revise job → 409
    chapter_write_in_progress);
  - frame sequence started → revising → done{chapter, revision};
  - in-range draft → zero-cost no-op (revision "in_range", draft untouched);
  - the endpoint is on the tight write rate-limit budget (covered in
    test_rate_limit.py).

The worker/two-pass internals are unit-tested in test_write_jobs.py; here we
drive the real endpoint through the TestClient.
"""
from __future__ import annotations

import json
import time
from collections.abc import Iterator
from typing import Any

from app.llm.base import StreamChunk, get_writer_llm_client
from app.main import app
from app.models.chapter import Chapter
from app.services.write_jobs import write_registry
from tests.conftest import MockLLMClient


class _EndpointReviseLLM(MockLLMClient):
    """``complete()`` returns a fixed revision after a small sleep (so the
    revising frame is reliably observed before the job goes terminal)."""

    def __init__(self, revision: str, *, revise_sleep: float = 0.15) -> None:
        self.revision = revision
        self.revise_sleep = revise_sleep
        self.complete_calls = 0

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        self.complete_calls += 1
        time.sleep(self.revise_sleep)
        return self.revision


def _parse_sse(text: str) -> list[tuple[str, dict | None]]:
    out: list[tuple[str, dict | None]] = []
    for block in text.strip().split("\n\n"):
        if not block or block.startswith(":"):
            continue
        lines = block.splitlines()
        event = lines[0].removeprefix("event: ").strip()
        data = json.loads(lines[1].removeprefix("data: ").strip()) if len(lines) > 1 else None
        out.append((event, data))
    return out


def _seed_draft_ready(client, auth_headers, db_session, *, draft_text: str, target: int = 1000) -> dict:
    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "修订", "cover_color": "#123456"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "第一章", "user_prompt": "作者本章剧情叙述。"},
    ).json()
    row = db_session.get(Chapter, chapter["id"])
    row.status = "draft_ready"
    row.draft_text = draft_text
    row.structured_prompt = {
        "target_word_count": target,
        "plot_anchors": ["关键事件甲"],
        "chapter_style": "冷静克制。",
    }
    db_session.commit()
    return chapter


def test_revise_requires_draft_ready(client, auth_headers, db_session):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "x"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "c", "user_prompt": "p"}
    ).json()
    # Fresh chapter is 'draft' — not draft_ready.
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/revise", headers=auth_headers)
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"


def test_revise_conflicts_with_live_job(client, auth_headers, db_session):
    chapter = _seed_draft_ready(client, auth_headers, db_session, draft_text="字" * 1000)
    # A live write job (reserved, phase 'streaming', non-terminal) → 409.
    write_registry.reserve(
        chapter["id"], previous_status="prompt_ready", context={}, llm=MockLLMClient(), writer_persona="p"
    )
    resp = client.post(f"/api/v1/chapters/{chapter['id']}/revise", headers=auth_headers)
    assert resp.status_code == 409
    assert resp.json()["error"]["kind"] == "conflict"


def test_revise_overlong_draft_frame_sequence_and_persist(client, auth_headers, db_session):
    chapter = _seed_draft_ready(client, auth_headers, db_session, draft_text="字" * 2000, target=1000)
    mock = _EndpointReviseLLM("改" * 1000)  # 2000 > 上沿1200 → revise → 1000 in range
    app.dependency_overrides[get_writer_llm_client] = lambda: mock

    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/revise", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))

    names = [f[0] for f in frames]
    # 审后 🟡3 — actual /revise帧序 (locked): started → token(buffer seed 整稿回放) →
    # progress → revising → done. The seeded [draft_text] is replayed as one token
    # frame (send_snapshot=False), which the frontend is built to consume.
    assert names[0] == "started"
    assert "token" in names
    tok = [d for n, d in frames if n == "token"][0]
    assert tok["text"] == "字" * 2000  # the original draft, replayed verbatim
    assert names.index("token") < names.index("revising")
    assert "revising" in names
    assert names[-1] == "done"
    done = [d for n, d in frames if n == "done"][0]
    assert done["revision"] == "revised"
    assert done["chapter"]["status"] == "draft_ready"
    assert mock.complete_calls == 1

    row = db_session.get(Chapter, chapter["id"])
    db_session.refresh(row)
    assert row.draft_text == "改" * 1000


def test_revise_empty_result_preserves_original_draft(client, auth_headers, db_session):
    """🔴1 (发版硬门): /revise where the upstream returns empty content must NOT
    wipe the stored draft — degrade to ``unrevised``, original preserved
    (unrecoverable data loss otherwise, per reviewer)."""
    chapter = _seed_draft_ready(client, auth_headers, db_session, draft_text="原" * 2000, target=1000)
    mock = _EndpointReviseLLM("", revise_sleep=0.0)  # 200 + empty content
    app.dependency_overrides[get_writer_llm_client] = lambda: mock

    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/revise", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))

    done = [d for n, d in frames if n == "done"][0]
    assert done["revision"] == "unrevised"
    row = db_session.get(Chapter, chapter["id"])
    db_session.refresh(row)
    assert row.draft_text == "原" * 2000  # original preserved, not wiped to ""


def test_revise_in_range_draft_is_noop(client, auth_headers, db_session):
    chapter = _seed_draft_ready(client, auth_headers, db_session, draft_text="字" * 1000, target=1000)
    mock = _EndpointReviseLLM("改" * 500)  # would-be revision, but 1000 ∈ range → never called
    app.dependency_overrides[get_writer_llm_client] = lambda: mock

    with client.stream("POST", f"/api/v1/chapters/{chapter['id']}/revise", headers=auth_headers) as r:
        frames = _parse_sse("".join(r.iter_text()))

    names = [f[0] for f in frames]
    assert names[0] == "started"
    assert names[-1] == "done"
    done = [d for n, d in frames if n == "done"][0]
    assert done["revision"] == "in_range"
    assert mock.complete_calls == 0  # no LLM cost for an in-range draft

    row = db_session.get(Chapter, chapter["id"])
    db_session.refresh(row)
    assert row.draft_text == "字" * 1000  # untouched
