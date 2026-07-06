import XCTest
@testable import LinoWriting

/// PROJECT_PLAN §4 v1.3.0 (II) P1 — 角色卡编辑补全 store-level contract.
///
/// Covers the add/remove paths newly wired to the UI in P1
/// (固定设定/动态字段/作者笔记 each gained "+" and per-row delete, plus
/// card-head name/role become editable). The view layer (`MacCharacterTab` /
/// `IOSCharactersSection`) is a thin wrapper around these `CharactersStore`
/// methods — this file is the ground truth that the wiring behaves
/// correctly end-to-end against `MockAPIClient.patchCharacter`'s
/// whole-object-replace semantics (same contract the real backend PATCH
/// endpoint implements).
@MainActor
final class CharactersStoreEditingTests: XCTestCase {

    private func makeCharacter(
        frozen: [String: JSONValue] = [:],
        live: [String: JSONValue] = [:],
        notes: [String: JSONValue] = [:]
    ) -> Character {
        Character(
            id: "c1",
            bookId: "b1",
            name: "林夕",
            role: "主角",
            frozenFields: frozen,
            liveFields: live,
            authorNotes: notes,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - frozen_fields add / remove

    func test_updateFrozenField_addsNewKey() async {
        let mock = MockAPIClient()
        let character = makeCharacter(frozen: ["背景": .string("退役猎人")])
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.updateFrozenField(character, key: "性格", value: .string("谨慎多疑"))

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertEqual(updated?.frozenFields["背景"], .string("退役猎人"), "existing key preserved")
        XCTAssertEqual(updated?.frozenFields["性格"], .string("谨慎多疑"), "new key added")
    }

    func test_removeFrozenField_deletesKey() async {
        let mock = MockAPIClient()
        let character = makeCharacter(frozen: ["背景": .string("退役猎人"), "性格": .string("谨慎多疑")])
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.removeFrozenField(character, key: "性格")

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertNil(updated?.frozenFields["性格"])
        XCTAssertEqual(updated?.frozenFields["背景"], .string("退役猎人"), "sibling key untouched")
    }

    // MARK: - live_fields add / remove (existing paths, still covered end-to-end)

    func test_updateLiveField_addsNewKey_onEmptyCard() async {
        let mock = MockAPIClient()
        let character = makeCharacter()
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.updateLiveField(character, key: "当前状态", value: .string("在山洞养伤"))

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertEqual(updated?.liveFields["当前状态"], .string("在山洞养伤"))
    }

    func test_removeLiveField_deletesKey() async {
        let mock = MockAPIClient()
        let character = makeCharacter(live: ["当前状态": .string("在山洞养伤")])
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.removeLiveField(character, key: "当前状态")

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertEqual(updated?.liveFields, [:])
    }

    // MARK: - author_notes add / remove

    func test_updateAuthorNote_addsNewKey_onEmptyCard() async {
        let mock = MockAPIClient()
        let character = makeCharacter()
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.updateAuthorNote(character, key: "隐藏动机", value: .string("想找回妹妹"))

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertEqual(updated?.authorNotes["隐藏动机"], .string("想找回妹妹"))
    }

    func test_removeAuthorNote_deletesKey() async {
        let mock = MockAPIClient()
        let character = makeCharacter(notes: ["隐藏动机": .string("想找回妹妹"), "伤痛": .string("童年目睹屠村")])
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.removeAuthorNote(character, key: "隐藏动机")

        let updated = store.characters.first(where: { $0.id == "c1" })
        XCTAssertNil(updated?.authorNotes["隐藏动机"])
        XCTAssertEqual(updated?.authorNotes["伤痛"], .string("童年目睹屠村"))
    }

    // MARK: - card-head name / role editable

    func test_updateName_changesDisplayName() async {
        let mock = MockAPIClient()
        let character = makeCharacter()
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.updateName(character, to: "沈墨")

        XCTAssertEqual(store.characters.first(where: { $0.id == "c1" })?.name, "沈墨")
    }

    func test_updateRole_changesRole() async {
        let mock = MockAPIClient()
        let character = makeCharacter()
        mock.characters = [character]
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        await store.updateRole(character, to: "反派")

        XCTAssertEqual(store.characters.first(where: { $0.id == "c1" })?.role, "反派")
    }

    // MARK: - error path: failed PATCH publishes to errorBus, leaves state untouched

    func test_updateFrozenField_publishesError_onApiFailure() async {
        let mock = MockAPIClient()
        let character = makeCharacter(frozen: ["背景": .string("退役猎人")])
        mock.characters = [character]
        let bus = ErrorBus()
        let store = CharactersStore(api: mock, errorBus: bus)
        await store.load(bookId: "b1")

        mock.errorToThrow = .notFound("character")
        await store.updateFrozenField(character, key: "性格", value: .string("谨慎多疑"))

        // Store state unchanged (patch never applied since the mock threw
        // before mutating `mock.characters`, and CharactersStore only
        // updates its local array from the return value).
        let unchanged = store.characters.first(where: { $0.id == "c1" })
        XCTAssertNil(unchanged?.frozenFields["性格"], "failed PATCH must not locally apply the new field")
        XCTAssertEqual(unchanged?.frozenFields["背景"], .string("退役猎人"))
    }

    // MARK: - v1.3.0 (II) P2 — importFromText ("导入人物卡" LLM parse)

    func test_importFromText_mergesReturnedCharactersIntoStore() async {
        let mock = MockAPIClient()
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        let parsed = [
            Character(id: "p1", bookId: "b1", name: "沈墨", role: "配角", createdAt: Date(), updatedAt: Date()),
            Character(id: "p2", bookId: "b1", name: "阿离", role: nil, createdAt: Date(), updatedAt: Date()),
        ]
        mock.onParseCharacters = { bookId, rawText in
            XCTAssertEqual(bookId, "b1")
            XCTAssertEqual(rawText, "沈墨是配角…阿离是…")
            return parsed
        }

        let result = await store.importFromText(bookId: "b1", rawText: "沈墨是配角…阿离是…")

        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(store.characters.contains(where: { $0.id == "p1" }))
        XCTAssertTrue(store.characters.contains(where: { $0.id == "p2" }))
    }

    func test_importFromText_returnsEmptyArray_whenLlmParsesNothing_doesNotCrash() async {
        let mock = MockAPIClient()
        let store = CharactersStore(api: mock, errorBus: ErrorBus())
        await store.load(bookId: "b1")

        mock.onParseCharacters = { _, _ in [] }

        let result = await store.importFromText(bookId: "b1", rawText: "没有角色的文本")

        XCTAssertEqual(result, [], "empty parse result must be non-nil [] so the sheet shows '未能解析出角色', not a Toast")
        XCTAssertEqual(store.characters.count, 0)
    }

    func test_importFromText_publishesErrorAndReturnsNil_onApiFailure() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = CharactersStore(api: mock, errorBus: bus)
        await store.load(bookId: "b1")

        mock.errorToThrow = .upstream("解析失败", retryable: false)

        let result = await store.importFromText(bookId: "b1", rawText: "一些文本")

        XCTAssertNil(result)
        XCTAssertEqual(store.characters.count, 0)
    }

    // MARK: - 审后修复 🟡#1 — CardHeadFieldCommit (name clear = cancel, not a store call)

    func test_cardHeadFieldCommit_emptyName_isCancelled_doesNotResolve() {
        // Mirrors MacCardHeadField/IOSCardHeadField's name usage
        // (allowsEmpty: false): clearing the field and blurring must NOT
        // produce a value to commit, so the call site never invokes
        // `charactersStore.updateName` / PATCHes an empty name.
        let resolved = CardHeadFieldCommit.resolve(draft: "   ", original: "林夕", allowsEmpty: false)
        XCTAssertNil(resolved, "clearing a non-empty-allowed field must cancel, not commit \"\"")
    }

    func test_cardHeadFieldCommit_emptyRole_isAllowed_resolvesToEmptyString() {
        // role (allowsEmpty: true) keeps the pre-fix behavior: blank is a
        // legal "no role" value and does reach the store/PATCH.
        let resolved = CardHeadFieldCommit.resolve(draft: "  ", original: "主角", allowsEmpty: true)
        XCTAssertEqual(resolved, "", "role may be legally cleared to empty")
    }

    func test_cardHeadFieldCommit_unchangedValue_isNoOp() {
        let resolved = CardHeadFieldCommit.resolve(draft: "林夕", original: "林夕", allowsEmpty: false)
        XCTAssertNil(resolved, "unchanged value must not re-commit")
    }
}
