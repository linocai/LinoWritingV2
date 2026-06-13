import XCTest
@testable import LinoWriting

/// PROJECT_PLAN v1.0.0 EE Phase 4 (前端) — outline panel + persona editor +
/// Step2 directive store/codec logic.
///
/// Coverage:
///  - OutlineStore: load (nil when never ingested) / ingest upsert / patch;
///    every success replaces `outline` with the server copy.
///  - PersonaStore: load three rows / save flips is_default semantics in store
///    state / per-role mutating flag clears.
///  - StructuredPrompt: `chapter_directive` round-trips snake_case and
///    `decodeIfPresent` tolerates an absent key (legacy payload → nil).
///  - OutlineWriteRequest / AgentPersonaUpdateRequest encode snake_case bodies.
@MainActor
final class Phase4OutlinePersonaTests: XCTestCase {

    // MARK: - OutlineStore

    func test_outline_load_nilWhenNeverIngested() async {
        let mock = MockAPIClient()
        let store = OutlineStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")
        XCTAssertNil(store.outline)
        XCTAssertEqual(store.rawText, "")
        XCTAssertTrue(mock.calls.contains("getOutline"))
    }

    func test_outline_ingest_upsertsThenLoadReadsBack() async {
        let mock = MockAPIClient()
        let store = OutlineStore(api: mock, errorBus: ErrorBus())
        let saved = await store.ingest(bookId: "b1", rawText: "我的大纲")
        XCTAssertEqual(saved?.rawText, "我的大纲")
        XCTAssertEqual(store.outline?.rawText, "我的大纲")
        // A fresh load on the same book reads the upserted row back.
        let store2 = OutlineStore(api: mock, errorBus: ErrorBus())
        await store2.load(bookId: "b1")
        XCTAssertEqual(store2.outline?.rawText, "我的大纲")
    }

    func test_outline_patch_overwritesStoredText() async {
        let mock = MockAPIClient()
        let store = OutlineStore(api: mock, errorBus: ErrorBus())
        _ = await store.ingest(bookId: "b1", rawText: "v1")
        let patched = await store.patch(bookId: "b1", rawText: "v2")
        XCTAssertEqual(patched?.rawText, "v2")
        XCTAssertEqual(store.outline?.rawText, "v2")
    }

    func test_outline_failure_publishesAndKeepsPriorState() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = OutlineStore(api: mock, errorBus: bus)
        _ = await store.ingest(bookId: "b1", rawText: "good")
        mock.errorToThrow = .transport("boom")
        let result = await store.patch(bookId: "b1", rawText: "bad")
        XCTAssertNil(result)
        XCTAssertEqual(store.outline?.rawText, "good")  // unchanged
        XCTAssertNotNil(bus.current)
    }

    // MARK: - PersonaStore

    func test_persona_load_returnsThreeRowsInOrder() async {
        let mock = MockAPIClient()
        let store = PersonaStore(api: mock, errorBus: ErrorBus())
        await store.load()
        XCTAssertEqual(store.personas.map { $0.agentRole }, [.expander, .writer, .extractor])
        XCTAssertTrue(store.personas.allSatisfy { $0.isDefault })
    }

    func test_persona_save_flipsIsDefaultFalseInStore() async {
        let mock = MockAPIClient()
        let store = PersonaStore(api: mock, errorBus: ErrorBus())
        await store.load()
        let updated = await store.save(role: .writer, systemPrompt: "新人格")
        XCTAssertEqual(updated?.systemPrompt, "新人格")
        XCTAssertEqual(updated?.isDefault, false)
        // Store row for writer is replaced; the others untouched.
        XCTAssertEqual(store.persona(for: .writer)?.systemPrompt, "新人格")
        XCTAssertEqual(store.persona(for: .writer)?.isDefault, false)
        XCTAssertEqual(store.persona(for: .expander)?.isDefault, true)
        // Mock captured the snake_case-encoded payload role + text.
        XCTAssertEqual(mock.lastPersonaPatch?.role, .writer)
        XCTAssertEqual(mock.lastPersonaPatch?.systemPrompt, "新人格")
    }

    func test_persona_reset_restoresDefaultFlag() async {
        let mock = MockAPIClient()
        let store = PersonaStore(api: mock, errorBus: ErrorBus())
        await store.load()
        _ = await store.save(role: .extractor, systemPrompt: "改过")
        XCTAssertEqual(store.persona(for: .extractor)?.isDefault, false)
        let restored = await store.reset(role: .extractor)
        XCTAssertEqual(restored?.isDefault, true)
        XCTAssertEqual(store.persona(for: .extractor)?.isDefault, true)
    }

    func test_persona_mutatingFlagClearsAfterSave() async {
        let mock = MockAPIClient()
        let store = PersonaStore(api: mock, errorBus: ErrorBus())
        await store.load()
        _ = await store.save(role: .writer, systemPrompt: "x")
        XCTAssertFalse(store.isMutating(.writer))
    }

    // MARK: - StructuredPrompt.chapterDirective codec

    func test_directive_roundTripsSnakeCase() throws {
        var sp = StructuredPrompt(chapterGoal: "g")
        sp.chapterDirective = "本章方向"
        let data = try CodecFactory.makeEncoder().encode(sp)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"chapter_directive\""), "expected snake_case key, got: \(json)")
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: data)
        XCTAssertEqual(decoded.chapterDirective, "本章方向")
    }

    func test_directive_absentKeyDecodesAsNil() throws {
        // Legacy payload with no chapter_directive key at all.
        let legacy = Data("""
        {"chapter_goal":"g","must_happen":[],"must_not_happen":[],"characters_involved":[]}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertNil(decoded.chapterDirective)
        XCTAssertEqual(decoded.chapterGoal, "g")
    }

    // MARK: - Request body encoding

    func test_outlineWriteRequest_encodesSnakeCase() throws {
        let data = try CodecFactory.makeEncoder().encode(OutlineWriteRequest(rawText: "abc"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"raw_text\""))
        XCTAssertTrue(json.contains("abc"))
    }

    func test_personaUpdateRequest_encodesSnakeCase() throws {
        let data = try CodecFactory.makeEncoder().encode(AgentPersonaUpdateRequest(systemPrompt: "p"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"system_prompt\""))
    }
}
