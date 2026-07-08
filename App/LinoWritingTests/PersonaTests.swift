import XCTest
@testable import LinoWriting

/// PROJECT_PLAN v1.0.0 EE Phase 4 (前端) — persona editor + Step2 directive
/// store/codec logic.
///
/// v1.3.0 (JJ) P8 — split off from `Phase4OutlinePersonaTests.swift` (renamed
/// to this file): the outline half (`OutlineStore` tests +
/// `OutlineWriteRequest` encoding) is deleted along with the whole outline
/// module (P6); this file keeps the persona half untouched.
///
/// Coverage:
///  - PersonaStore: load three rows / save flips is_default semantics in store
///    state / per-role mutating flag clears.
///  - StructuredPrompt: v1.4.0 (MM) P1/P3 — `chapter_directive` field removed
///    (legacy payloads carrying the residual key still decode successfully,
///    silently ignored); `continuity_alerts` round-trips snake_case.
///  - AgentPersonaUpdateRequest encodes a snake_case body.
@MainActor
final class PersonaTests: XCTestCase {

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

    // MARK: - StructuredPrompt codec (v1.4.0 MM P1/P3)

    func test_directive_residualKeyStillDecodesAndIsIgnored() throws {
        // Legacy payload with a residual `chapter_directive` key from a chapter
        // written before v1.4.0 — the field no longer exists on the model, but
        // decoding must still succeed and simply drop the unknown key.
        let legacy = Data("""
        {"chapter_goal":"g","must_happen":[],"must_not_happen":[],"characters_involved":[],
         "chapter_directive":"本章方向"}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertEqual(decoded.chapterGoal, "g")
        XCTAssertEqual(decoded.continuityAlerts, [])
    }

    func test_continuityAlerts_roundTripsSnakeCase() throws {
        var sp = StructuredPrompt(chapterGoal: "g")
        sp.continuityAlerts = ["第三章提到的信物本章未回收"]
        let data = try CodecFactory.makeEncoder().encode(sp)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"continuity_alerts\""), "expected snake_case key, got: \(json)")
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: data)
        XCTAssertEqual(decoded.continuityAlerts, ["第三章提到的信物本章未回收"])
    }

    func test_continuityAlerts_absentKeyDecodesAsEmpty() throws {
        // Legacy payload with no continuity_alerts key at all.
        let legacy = Data("""
        {"chapter_goal":"g","must_happen":[],"must_not_happen":[],"characters_involved":[]}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertEqual(decoded.continuityAlerts, [])
        XCTAssertEqual(decoded.chapterGoal, "g")
    }

    // MARK: - Request body encoding

    func test_personaUpdateRequest_encodesSnakeCase() throws {
        let data = try CodecFactory.makeEncoder().encode(AgentPersonaUpdateRequest(systemPrompt: "p"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"system_prompt\""))
    }
}
