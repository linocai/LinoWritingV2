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
///  - StructuredPrompt: v1.5.0 (NN) P2 — `chapter_goal`/`must_not_happen`/
///    `extra_notes`/`focus_traits` deleted; `must_happen`→`plot_anchors`
///    (old key does NOT populate the renamed field); new `chapter_style`
///    round-trips snake_case + absent-key decodes as nil. Old residual keys
///    (`chapter_goal`/`must_happen`/`chapter_directive`/etc.) still decode
///    successfully and are silently ignored.
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

    // MARK: - StructuredPrompt codec (v1.5.0 NN P2)

    func test_legacyKeys_residualAndIgnored() throws {
        // Legacy payload from a chapter written before v1.5.0 carrying every
        // now-deleted key (`chapter_goal`/`must_not_happen`/`extra_notes`/
        // `focus_traits`/`chapter_directive`) plus the *old* `must_happen`
        // key — none of these exist on the model anymore, so decoding must
        // still succeed, silently drop them all, and (crucially) NOT map the
        // old `must_happen` onto the renamed `plot_anchors` field.
        let legacy = Data("""
        {"chapter_goal":"g","must_happen":["旧锚点"],"must_not_happen":["x"],
         "extra_notes":"n","focus_traits":["t"],"chapter_directive":"本章方向",
         "characters_involved":[]}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertEqual(decoded.plotAnchors, [])
        XCTAssertEqual(decoded.continuityAlerts, [])
        XCTAssertNil(decoded.chapterStyle)
    }

    func test_plotAnchors_roundTripsSnakeCase() throws {
        var sp = StructuredPrompt()
        sp.plotAnchors = ["主角发现信物"]
        let data = try CodecFactory.makeEncoder().encode(sp)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"plot_anchors\""), "expected snake_case key, got: \(json)")
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: data)
        XCTAssertEqual(decoded.plotAnchors, ["主角发现信物"])
    }

    func test_chapterStyle_roundTripsSnakeCase() throws {
        var sp = StructuredPrompt()
        sp.chapterStyle = "短句、快节奏、克制"
        let data = try CodecFactory.makeEncoder().encode(sp)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"chapter_style\""), "expected snake_case key, got: \(json)")
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: data)
        XCTAssertEqual(decoded.chapterStyle, "短句、快节奏、克制")
    }

    func test_chapterStyle_absentKeyDecodesAsNil() throws {
        let legacy = Data("""
        {"plot_anchors":[],"characters_involved":[]}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertNil(decoded.chapterStyle)
    }

    func test_continuityAlerts_roundTripsSnakeCase() throws {
        var sp = StructuredPrompt()
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
        {"plot_anchors":[],"characters_involved":[]}
        """.utf8)
        let decoded = try CodecFactory.makeDecoder().decode(StructuredPrompt.self, from: legacy)
        XCTAssertEqual(decoded.continuityAlerts, [])
    }

    // MARK: - Request body encoding

    func test_personaUpdateRequest_encodesSnakeCase() throws {
        let data = try CodecFactory.makeEncoder().encode(AgentPersonaUpdateRequest(systemPrompt: "p"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"system_prompt\""))
    }
}
