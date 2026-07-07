"""v1.3.0 (II) P2 — POST /books/{id}/characters/parse.

PROJECT_PLAN §4 P2 acceptance (9 backend scenarios, mocked extractor LLM):
1. normal raw_text → 201 + N characters (name + frozen_fields + author_notes,
   live_fields {}), DB actually holds N rows.
2. raw_text empty/whitespace-only → 422.
3. raw_text > 50000 chars → 422.
4. LLM raises → 502 envelope.
5. LLM returns illegal JSON / non-array `characters` → 502 envelope.
6. LLM returns an empty array → 201 + items: [].
7. an item missing `name` → skipped, the rest still land.
8. same-name-as-existing → skipped (not overwritten, not duplicated);
   `items` only lists the actually-new character.
9. no active LLM key → 502 `no_active_llm_key` envelope.
"""
from __future__ import annotations

from typing import Any

import pytest

from app.llm.base import get_extractor_llm_client
from app.main import app


class _StubExtractorLLM:
    """Returns a fixed parse result. Tests configure ``result`` (a dict to
    hand back from ``complete_json``) or ``raise_exc`` (an exception to
    raise instead)."""

    def __init__(self, result: dict[str, Any] | None = None, raise_exc: Exception | None = None) -> None:
        self.result = result
        self.raise_exc = raise_exc

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:  # pragma: no cover - unused
        raise NotImplementedError

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        if self.raise_exc is not None:
            raise self.raise_exc
        assert self.result is not None
        return self.result

    def complete_stream(self, *, system: str, user: str, **kwargs: Any):  # pragma: no cover - unused
        raise NotImplementedError
        yield  # pragma: no cover


def _override_extractor(stub: _StubExtractorLLM) -> None:
    app.dependency_overrides[get_extractor_llm_client] = lambda: stub


def _clear_extractor_override() -> None:
    app.dependency_overrides.pop(get_extractor_llm_client, None)


@pytest.fixture(autouse=True)
def _cleanup_override():
    yield
    _clear_extractor_override()


def _make_book(client, auth_headers) -> str:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "解析测试"}).json()
    return book["id"]


# 1. normal raw_text → 201 + N characters, DB actually holds N rows.
def test_parse_characters_happyPath_landsAllFields(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={
        "characters": [
            {
                "name": "林夕",
                "role": "主角",
                "frozen_fields": {"背景": "退役猎人", "性格": "谨慎多疑"},
                "author_notes": {"隐藏动机": "想找回妹妹"},
            },
            {
                "name": "黑刀",
                "role": "反派",
                "frozen_fields": {"背景": "山匪头子"},
                "author_notes": {},
            },
        ]
    }))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "林夕，退役猎人，谨慎多疑，想找回妹妹。黑刀，山匪头子。"},
    )
    assert response.status_code == 201
    items = response.json()["items"]
    assert len(items) == 2
    lin = next(item for item in items if item["name"] == "林夕")
    assert lin["frozen_fields"]["背景"] == "退役猎人"
    assert lin["author_notes"]["隐藏动机"] == "想找回妹妹"
    assert lin["live_fields"] == {}

    list_response = client.get(f"/api/v1/books/{book_id}/characters", headers=auth_headers)
    assert len(list_response.json()["items"]) == 2


# 建议级修复 — LLM 返回嵌套/非字符串 value 落库后归一为可读字符串（不再显示空串）。
def test_parse_characters_nonStringFieldValues_normalizedToReadableStrings(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={
        "characters": [
            {
                "name": "沈墨",
                "role": "配角",
                "frozen_fields": {
                    "背景": {"出身": "山匪", "年龄": 34},  # nested dict
                    "特长": ["刀法", "追踪"],  # list
                    "身高": 180,  # int
                },
                "author_notes": {"是否死亡": False},  # bool
            },
        ]
    }))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "沈墨，山匪出身，34岁，擅长刀法与追踪，身高180，未死亡。"},
    )
    assert response.status_code == 201
    item = response.json()["items"][0]
    # every value lands as a non-empty, readable string — never the bare
    # object/number/bool that would render blank via the frontend's
    # `.string`-only stringValue helper.
    assert item["frozen_fields"]["背景"] == '{"出身": "山匪", "年龄": 34}'
    assert item["frozen_fields"]["特长"] == '["刀法", "追踪"]'
    assert item["frozen_fields"]["身高"] == "180"
    assert item["author_notes"]["是否死亡"] == "False"


# 2. raw_text empty/whitespace-only → 422.
@pytest.mark.parametrize("raw_text", ["", "   ", "\n\n\t"])
def test_parse_characters_emptyOrWhitespaceRawText_422(client, auth_headers, raw_text):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": []}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": raw_text},
    )
    assert response.status_code == 422


# 3. raw_text > 50000 chars → 422.
def test_parse_characters_rawTextTooLong_422(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": []}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "x" * 50001},
    )
    assert response.status_code == 422


# 4. LLM raises → 502 envelope.
def test_parse_characters_llmRaises_502(client, auth_headers):
    from app.llm.errors import LLMError

    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(raise_exc=LLMError("upstream exploded", retryable=True)))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "一些人物设定文本"},
    )
    assert response.status_code == 502
    body = response.json()
    assert body["error"]["kind"] == "upstream"


# 5a. LLM returns non-array `characters` → 502 envelope.
def test_parse_characters_llmReturnsNonArrayCharacters_502(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": "not-an-array"}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "一些人物设定文本"},
    )
    assert response.status_code == 502
    assert response.json()["error"]["kind"] == "upstream"


# 5b. LLM returns illegal JSON (complete_json's own contract: raises LLMError
# on JSONDecodeError) → still surfaces as 502 through the same router catch.
def test_parse_characters_llmReturnsMalformedJson_502(client, auth_headers):
    from app.llm.errors import LLMError

    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(raise_exc=LLMError("LLM returned invalid JSON: boom", retryable=False)))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "一些人物设定文本"},
    )
    assert response.status_code == 502


# 6. LLM returns an empty array → 201 + items: [].
def test_parse_characters_llmReturnsEmptyArray_201EmptyItems(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": []}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "这段文本里其实没有任何角色设定"},
    )
    assert response.status_code == 201
    assert response.json()["items"] == []


# 7. an item missing `name` → skipped, the rest still land.
def test_parse_characters_itemMissingName_skippedRestLand(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={
        "characters": [
            {"role": "无名氏", "frozen_fields": {}},  # missing name -> skip
            {"name": "沈墨", "role": "配角", "frozen_fields": {}, "author_notes": {}},
        ]
    }))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "沈墨，配角。"},
    )
    assert response.status_code == 201
    items = response.json()["items"]
    assert len(items) == 1
    assert items[0]["name"] == "沈墨"


# 8. same-name-as-existing → skipped; items only lists the actually-new one.
# Also covers within-batch duplicate names skipping the second occurrence.
def test_parse_characters_sameNameAsExisting_skipped(client, auth_headers):
    book_id = _make_book(client, auth_headers)
    existing = client.post(
        f"/api/v1/books/{book_id}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角"},
    ).json()

    _override_extractor(_StubExtractorLLM(result={
        "characters": [
            {"name": "林夕", "role": "主角（重复）", "frozen_fields": {"背景": "不应落地"}},
            {"name": "沈墨", "role": "配角", "frozen_fields": {}},
            {"name": "沈墨", "role": "配角（批内重复）", "frozen_fields": {}},
        ]
    }))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "林夕...沈墨..."},
    )
    assert response.status_code == 201
    items = response.json()["items"]
    assert len(items) == 1
    assert items[0]["name"] == "沈墨"

    list_response = client.get(f"/api/v1/books/{book_id}/characters", headers=auth_headers)
    all_items = list_response.json()["items"]
    assert len(all_items) == 2  # original 林夕 (untouched) + new 沈墨
    lin = next(item for item in all_items if item["id"] == existing["id"])
    assert lin["frozen_fields"] == {}  # untouched, not overwritten by the "duplicate" parse item


# 9. no active LLM key → 502 `no_active_llm_key` envelope.
def test_parse_characters_noActiveLlmKey_502(client, auth_headers):
    from app.llm.base import get_llm_client, get_writer_llm_client, get_expander_llm_client

    book_id = _make_book(client, auth_headers)
    # Clear every per-Agent + generic override so the real factory path
    # runs and hits "no ProviderKey configured" (mirrors the pattern
    # documented by conftest's clear_all_llm_overrides helper).
    for dep in (get_llm_client, get_writer_llm_client, get_extractor_llm_client, get_expander_llm_client):
        app.dependency_overrides.pop(dep, None)

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "一些人物设定文本"},
    )
    assert response.status_code == 502
    body = response.json()
    assert body["error"]["kind"] == "upstream"
    assert body["error"]["details"]["code"] == "no_active_llm_key"


# v1.3.2 (LL) P4 — 落库异常状态码对齐: land_parsed_characters exploding during
# the commit transaction must 502 (not the bare 500 the old blanket
# ``except Exception: db.rollback(); raise`` produced), UNLESS it's an
# IntegrityError, which keeps the pre-existing 409 behaviour (carve-out
# BEFORE the blanket 502 — see routers/characters.py).
def test_parse_characters_landingRaisesGenericException_502(client, auth_headers, monkeypatch):
    import app.routers.characters as characters_router

    def _boom(db, book_id, items):
        raise RuntimeError("落库炸了")

    monkeypatch.setattr(characters_router, "land_parsed_characters", _boom)
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": [{"name": "林夕"}]}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "林夕，一名角色"},
    )
    assert response.status_code == 502
    assert response.json()["error"]["kind"] == "upstream"

    # And the failed landing was actually rolled back — no character/book
    # left in a half-committed state, no leaked internal exception text
    # required for the assertion above to hold.
    list_response = client.get(f"/api/v1/books/{book_id}/characters", headers=auth_headers)
    assert list_response.json()["items"] == []


def test_parse_characters_landingRaisesIntegrityError_409(client, auth_headers, monkeypatch):
    import app.routers.characters as characters_router
    from sqlalchemy.exc import IntegrityError

    def _boom(db, book_id, items):
        raise IntegrityError("INSERT INTO characters ...", {}, Exception("dup key"))

    monkeypatch.setattr(characters_router, "land_parsed_characters", _boom)
    book_id = _make_book(client, auth_headers)
    _override_extractor(_StubExtractorLLM(result={"characters": [{"name": "林夕"}]}))

    response = client.post(
        f"/api/v1/books/{book_id}/characters/parse",
        headers=auth_headers,
        json={"raw_text": "林夕，一名角色"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["kind"] == "conflict"
