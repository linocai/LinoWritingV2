import XCTest
@testable import LinoWriting

/// PROJECT_PLAN §5.B (Phase B-fld) — field-level dot indicator Codable + store
/// helper contract.
///
/// Covers:
/// - `Character` decodes `pending_field_highlights` when present.
/// - `Character` falls back to `[:]` for legacy payloads missing the key.
/// - snake_case round-trip preserves the dict.
/// - `CharacterPatchRequest` does NOT include the field (server-only state).
/// - `CharactersStore.cardHasPendingHighlight` integrates the legacy
///   `pendingHighlightIds` fallback with the new per-field server state.
@MainActor
final class CharacterFieldHighlightsTests: XCTestCase {

    // MARK: Character.pending_field_highlights decode

    func test_character_decodesPendingFieldHighlights_whenPresent() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "林夕",
          "role": "主角",
          "frozen_fields": {"core_traits": "谨慎"},
          "live_fields": {"current_status": "在山洞"},
          "author_notes": {},
          "pending_field_highlights": {
            "current_status": "2026-05-25T12:00:00Z",
            "knowledge": "2026-05-25T11:00:00Z"
          },
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T12:00:00Z"
        }
        """.data(using: .utf8)!
        let character = try CodecFactory.makeDecoder().decode(Character.self, from: json)
        XCTAssertEqual(character.pendingFieldHighlights["current_status"], "2026-05-25T12:00:00Z")
        XCTAssertEqual(character.pendingFieldHighlights["knowledge"], "2026-05-25T11:00:00Z")
        XCTAssertEqual(character.pendingFieldHighlights.count, 2)
    }

    func test_character_decodesPendingFieldHighlights_fallsBackToEmpty_whenMissing() throws {
        // Simulate a cached payload from pre-B-fld (no pending_field_highlights field).
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "黑刀",
          "role": "反派",
          "frozen_fields": {},
          "live_fields": {},
          "author_notes": {},
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T10:00:00Z"
        }
        """.data(using: .utf8)!
        let character = try CodecFactory.makeDecoder().decode(Character.self, from: json)
        XCTAssertEqual(character.pendingFieldHighlights, [:])
    }

    func test_character_roundTrip_preservesPendingFieldHighlights() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "林夕",
          "role": "主角",
          "frozen_fields": {},
          "live_fields": {"current_status": "新状态"},
          "author_notes": {},
          "pending_field_highlights": {"current_status": "2026-05-25T12:00:00Z"},
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T12:30:00Z"
        }
        """.data(using: .utf8)!
        let decoder = CodecFactory.makeDecoder()
        let encoder = CodecFactory.makeEncoder()
        let original = try decoder.decode(Character.self, from: json)
        let re = try encoder.encode(original)

        // Snake-case wire check.
        let obj = try JSONSerialization.jsonObject(with: re) as! [String: Any]
        XCTAssertNotNil(obj["pending_field_highlights"], "must emit pending_field_highlights snake_case key")
        XCTAssertNil(obj["pendingFieldHighlights"], "must not leak camelCase")
        let highlights = obj["pending_field_highlights"] as! [String: String]
        XCTAssertEqual(highlights["current_status"], "2026-05-25T12:00:00Z")

        let again = try decoder.decode(Character.self, from: re)
        XCTAssertEqual(again, original)
    }

    // MARK: CharacterPatchRequest must NOT carry pending_field_highlights

    func test_characterPatchRequest_doesNotExposePendingFieldHighlights() throws {
        // Server-only state — clearing is a side effect of editing live_fields.
        // If a future contributor adds it to the patch payload (e.g.
        // mistakenly thinking the client needs to clear it manually),
        // this regression test fires.
        let payload = CharacterPatchRequest(
            liveFields: ["current_status": .string("新状态")]
        )
        let data = try CodecFactory.makeEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["pending_field_highlights"], "PATCH must not carry pending_field_highlights")
        XCTAssertNil(obj["pendingFieldHighlights"])
    }

    // MARK: CharactersStore.cardHasPendingHighlight integration

    func test_cardHasPendingHighlight_isTrue_whenPerFieldHighlightsNonEmpty() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = CharactersStore(api: mock, errorBus: bus)

        let character = Character(
            id: "c1",
            bookId: "b1",
            name: "林夕",
            pendingFieldHighlights: ["current_status": "2026-05-25T12:00:00Z"],
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertTrue(store.cardHasPendingHighlight(character),
                      "per-field highlights non-empty should light up the card-level dot")
    }

    func test_cardHasPendingHighlight_isTrue_whenLegacyIdFlagged() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = CharactersStore(api: mock, errorBus: bus)

        let character = Character(
            id: "c1",
            bookId: "b1",
            name: "林夕",
            createdAt: Date(),
            updatedAt: Date()
        )
        // Legacy mechanism: ChapterToolbar.markUpdated after finalize.
        store.markUpdated([character.id])

        XCTAssertTrue(store.cardHasPendingHighlight(character),
                      "legacy pendingHighlightIds flag should still light up the card-level dot")
    }

    func test_cardHasPendingHighlight_isFalse_whenBothSignalsClean() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = CharactersStore(api: mock, errorBus: bus)

        let character = Character(
            id: "c1",
            bookId: "b1",
            name: "无事的角色",
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertFalse(store.cardHasPendingHighlight(character))
        XCTAssertEqual(character.pendingFieldHighlights, [:])
    }
}
