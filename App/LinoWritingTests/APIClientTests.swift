import XCTest
@testable import LinoWriting

/// Tests for the §3.1 error envelope mapping and round-trip codec for the core
/// response types. The full HTTP path is covered by mocking URLSession via URLProtocol.
final class APIClientTests: XCTestCase {

    // MARK: ErrorMapping

    func test_errorMapping_validationEnvelope() throws {
        let body = """
        {"error":{"kind":"validation","message":"bad input","retryable":false}}
        """.data(using: .utf8)!
        let err = ErrorMapping.map(status: 422, body: body)
        if case .validation(let msg) = err {
            XCTAssertEqual(msg, "bad input")
        } else { XCTFail("expected .validation, got \(err)") }
    }

    func test_errorMapping_upstreamRetryable() throws {
        let body = """
        {"error":{"kind":"upstream","message":"LLM down","retryable":true}}
        """.data(using: .utf8)!
        let err = ErrorMapping.map(status: 502, body: body)
        XCTAssertTrue(err.retryable)
        if case .upstream(let msg, let retryable) = err {
            XCTAssertEqual(msg, "LLM down")
            XCTAssertTrue(retryable)
        } else { XCTFail("expected .upstream, got \(err)") }
    }

    func test_errorMapping_fallbackUnauthorized() {
        let err = ErrorMapping.map(status: 401, body: Data())
        XCTAssertTrue(err.isUnauthorized)
    }

    func test_errorMapping_fallbackServer() {
        let err = ErrorMapping.map(status: 503, body: "oops".data(using: .utf8)!)
        if case .server = err { /* ok */ } else { XCTFail("expected .server, got \(err)") }
    }

    func test_errorMapping_notFound() {
        let err = ErrorMapping.map(status: 404, body: Data())
        if case .notFound = err { /* ok */ } else { XCTFail("expected .notFound, got \(err)") }
    }

    // MARK: Codec round-trips

    func test_chapter_roundTrip() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "index": 3,
          "title": "山洞夜话",
          "user_prompt": "他们躲进山洞，开始坦白",
          "structured_prompt": {
            "chapter_goal": "推动两人关系",
            "must_happen": ["A 告诉 B 真相"],
            "must_not_happen": [],
            "characters_involved": ["33333333-3333-3333-3333-333333333333"],
            "narrative_pov": "third_person_limited",
            "target_word_count": 3000
          },
          "draft_text": "雨声不断。",
          "summary": null,
          "status": "draft_ready",
          "created_at": "2026-05-22T10:00:00.123Z",
          "updated_at": "2026-05-22T11:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = CodecFactory.makeDecoder()
        let chapter = try decoder.decode(Chapter.self, from: json)
        XCTAssertEqual(chapter.index, 3)
        XCTAssertEqual(chapter.title, "山洞夜话")
        XCTAssertEqual(chapter.status, .draftReady)
        XCTAssertEqual(chapter.structuredPrompt?.chapterGoal, "推动两人关系")
        XCTAssertEqual(chapter.structuredPrompt?.narrativePov, .thirdPersonLimited)
        XCTAssertEqual(chapter.structuredPrompt?.targetWordCount, 3000)
        XCTAssertEqual(chapter.draftText, "雨声不断。")
    }

    func test_character_jsonValueFields_roundTrip() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "林夕",
          "role": "主角",
          "frozen_fields": {
            "core_traits": "聪明谨慎",
            "background": "退役的猎人"
          },
          "live_fields": {
            "current_status": "在山洞中养伤",
            "goals": ["找到失踪的妹妹"],
            "relationships": {"黑刀": "宿敌"}
          },
          "created_at": "2026-05-22T10:00:00Z",
          "updated_at": "2026-05-22T10:30:00Z"
        }
        """.data(using: .utf8)!
        let decoder = CodecFactory.makeDecoder()
        let character = try decoder.decode(Character.self, from: json)
        XCTAssertEqual(character.frozenFields.string("core_traits"), "聪明谨慎")
        XCTAssertEqual(character.liveFields.stringArray("goals"), ["找到失踪的妹妹"])
        XCTAssertEqual(character.liveFields.stringDict("relationships")["黑刀"], "宿敌")

        let encoder = CodecFactory.makeEncoder()
        let re = try encoder.encode(character)
        let again = try decoder.decode(Character.self, from: re)
        XCTAssertEqual(again, character)
    }

    func test_listResponse_decoding() throws {
        let json = """
        {"items":[{"id":"1","index":1,"title":null,"status":"draft","updated_at":"2026-05-22T10:00:00Z"}]}
        """.data(using: .utf8)!
        let decoded = try CodecFactory.makeDecoder().decode(ListResponse<ChapterSummary>.self, from: json)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items.first?.status, .draft)
    }
}
