import XCTest
@testable import LinoWriting

/// PROJECT_PLAN §5.L.6 (L-3) — Character.author_notes Codable contract.
///
/// Covers:
/// - decoding a payload that includes `author_notes` (new backend)
/// - decoding a legacy payload missing `author_notes` (fallback to `[:]`)
/// - PATCH request serialises `author_notes` in snake_case
/// - StructuredPrompt.focus_traits round-trip + legacy fallback
final class CharacterAuthorNotesCodecTests: XCTestCase {

    // MARK: Character.author_notes decode

    func test_character_decodesAuthorNotes_whenPresent() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "林夕",
          "role": "主角",
          "frozen_fields": {"core_traits": "聪明谨慎"},
          "live_fields": {"current_status": "养伤"},
          "author_notes": {
            "motivation": "想救回妹妹",
            "wound": "童年目睹屠村",
            "secret": "其实是黑刀的私生女"
          },
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T10:00:00Z"
        }
        """.data(using: .utf8)!
        let character = try CodecFactory.makeDecoder().decode(Character.self, from: json)
        XCTAssertEqual(character.authorNotes.string("motivation"), "想救回妹妹")
        XCTAssertEqual(character.authorNotes.string("wound"), "童年目睹屠村")
        XCTAssertEqual(character.authorNotes.string("secret"), "其实是黑刀的私生女")
        XCTAssertEqual(character.frozenFields.string("core_traits"), "聪明谨慎")
    }

    func test_character_decodesAuthorNotes_fallsBackToEmpty_whenMissing() throws {
        // Simulate a cached payload from pre-L-1 (no author_notes field).
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "黑刀",
          "role": "反派",
          "frozen_fields": {},
          "live_fields": {},
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T10:00:00Z"
        }
        """.data(using: .utf8)!
        let character = try CodecFactory.makeDecoder().decode(Character.self, from: json)
        XCTAssertEqual(character.authorNotes, [:])
    }

    func test_character_roundTrip_preservesAuthorNotes() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "book_id": "22222222-2222-2222-2222-222222222222",
          "name": "林夕",
          "role": "主角",
          "frozen_fields": {"background": "退役的猎人"},
          "live_fields": {"goals": ["找妹妹"]},
          "author_notes": {"motivation": "救妹妹"},
          "created_at": "2026-05-25T10:00:00Z",
          "updated_at": "2026-05-25T10:30:00Z"
        }
        """.data(using: .utf8)!
        let decoder = CodecFactory.makeDecoder()
        let encoder = CodecFactory.makeEncoder()
        let original = try decoder.decode(Character.self, from: json)
        let re = try encoder.encode(original)
        let again = try decoder.decode(Character.self, from: re)
        XCTAssertEqual(again, original)
        XCTAssertEqual(again.authorNotes.string("motivation"), "救妹妹")
    }

    // MARK: CharacterPatchRequest encode

    func test_characterPatchRequest_encodesAuthorNotes_snakeCase() throws {
        let payload = CharacterPatchRequest(
            authorNotes: ["motivation": .string("救妹妹"), "wound": .string("童年目睹")]
        )
        let data = try CodecFactory.makeEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["author_notes"], "PATCH request must emit author_notes snake_case key")
        let notes = obj["author_notes"] as! [String: Any]
        XCTAssertEqual(notes["motivation"] as? String, "救妹妹")
        XCTAssertEqual(notes["wound"] as? String, "童年目睹")
        // Other fields should be omitted (Codable default — nil optionals encode nothing
        // only if we used a strategy. Here they encode as null; verify they're not
        // misnamed). We just check that the camelCase key never leaks.
        XCTAssertNil(obj["authorNotes"], "must not leak camelCase key")
    }

    func test_characterCreateRequest_encodesAuthorNotes_snakeCase() throws {
        let payload = CharacterCreateRequest(
            name: "林夕",
            authorNotes: ["secret": .string("私生女")]
        )
        let data = try CodecFactory.makeEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["author_notes"])
        XCTAssertNil(obj["authorNotes"])
    }

    // MARK: StructuredPrompt.focus_traits

    func test_structuredPrompt_decodesFocusTraits_whenPresent() throws {
        let json = """
        {
          "chapter_goal": "推动两人关系",
          "must_happen": [],
          "must_not_happen": [],
          "characters_involved": [],
          "focus_traits": ["谨慎", "对妹妹的愧疚"]
        }
        """.data(using: .utf8)!
        let prompt = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: json)
        XCTAssertEqual(prompt.focusTraits, ["谨慎", "对妹妹的愧疚"])
    }

    func test_structuredPrompt_decodesFocusTraits_fallsBackToEmpty_whenMissing() throws {
        let json = """
        {
          "chapter_goal": "推动两人关系",
          "must_happen": [],
          "must_not_happen": [],
          "characters_involved": []
        }
        """.data(using: .utf8)!
        let prompt = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: json)
        XCTAssertEqual(prompt.focusTraits, [])
    }

    func test_structuredPrompt_roundTrip_preservesFocusTraits() throws {
        let original = StructuredPrompt(
            chapterGoal: "山洞夜话",
            mustHappen: ["A 告诉 B 真相"],
            charactersInvolved: ["c1", "c2"],
            focusTraits: ["谨慎", "愧疚"]
        )
        let encoder = CodecFactory.makeEncoder()
        let decoder = CodecFactory.makeDecoder()
        let data = try encoder.encode(original)

        // Snake-case wire check.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["focus_traits"] as? [String], ["谨慎", "愧疚"])
        XCTAssertNil(obj["focusTraits"])

        let again = try decoder.decode(StructuredPrompt.self, from: data)
        XCTAssertEqual(again, original)
    }

    // MARK: ChapterPatchRequest carries focus_traits via structured_prompt

    func test_chapterPatchRequest_encodesStructuredPromptWithFocusTraits() throws {
        let req = ChapterPatchRequest(structuredPrompt: StructuredPrompt(
            chapterGoal: "x",
            focusTraits: ["谨慎"]
        ))
        let data = try CodecFactory.makeEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sp = obj["structured_prompt"] as! [String: Any]
        XCTAssertEqual(sp["focus_traits"] as? [String], ["谨慎"])
    }
}
