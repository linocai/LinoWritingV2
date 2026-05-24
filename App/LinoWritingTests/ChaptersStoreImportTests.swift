import XCTest
@testable import LinoWriting

/// Coverage for the §5.A Phase A-2 import path: `ChapterEditorStore.importChapter`,
/// `MockAPIClient.importChapter` behaviour, and the `ChapterImportRequest`
/// snake-case wire encoding.
@MainActor
final class ChaptersStoreImportTests: XCTestCase {

    // MARK: helpers

    private func makeBookAndChapter(_ mock: MockAPIClient) async -> (Book, Chapter) {
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "原始想法", title: nil)
        )
        return (book, chapter)
    }

    // MARK: success path

    func test_importChapter_success_marksFinalizedAndImported() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter) = await makeBookAndChapter(mock)

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        XCTAssertEqual(editor.chapter?.status, .draft)
        XCTAssertEqual(editor.chapter?.source, .agent)

        let payload = ChapterImportRequest(
            draftText: "用户手写的全章正文。",
            title: "新标题",
            summary: nil,
            runExtractor: true
        )
        let result = await editor.importChapter(payload)

        XCTAssertNotNil(result)
        XCTAssertEqual(editor.chapter?.status, .finalized)
        XCTAssertEqual(editor.chapter?.source, .imported)
        XCTAssertEqual(editor.chapter?.draftText, "用户手写的全章正文。")
        XCTAssertEqual(editor.chapter?.title, "新标题")
        XCTAssertFalse(editor.isImporting)
        XCTAssertNil(bus.current, "happy path must not publish to the error bus")
        XCTAssertEqual(mock.calls.last, "importChapter")
    }

    func test_importChapter_propagatesUpdatedCharacterIds() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter) = await makeBookAndChapter(mock)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        // Override the mock to simulate the Extractor touching one character.
        mock.onImport = { id, payload in
            // Build a finalized+imported chapter that matches the mock's
            // default contract, then attach a non-empty updatedCharacterIds.
            let now = Date()
            let updated = Chapter(
                id: id,
                bookId: chapter.bookId,
                index: chapter.index,
                title: payload.title ?? chapter.title,
                userPrompt: chapter.userPrompt,
                draftText: payload.draftText,
                summary: payload.summary,
                status: .finalized,
                source: .imported,
                createdAt: chapter.createdAt,
                updatedAt: now
            )
            return ChapterImportResponse(
                chapter: updated,
                updatedCharacterIds: ["c1", "c2"],
                addedEventIds: ["e1"]
            )
        }

        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "正文", runExtractor: true)
        )

        XCTAssertEqual(result?.updatedCharacterIds, ["c1", "c2"])
        XCTAssertEqual(result?.addedEventIds, ["e1"])
        XCTAssertEqual(editor.lastUpdatedCharacterIds, ["c1", "c2"],
                       "import should fan out into the same highlight pipe as finalize")
    }

    // MARK: failure path

    func test_importChapter_failure_publishesAndKeepsChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter) = await makeBookAndChapter(mock)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        // Simulate the backend's 409 "wrong status" rejection.
        mock.errorToThrow = .conflict("章节当前状态不允许 import")

        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "正文", runExtractor: true)
        )

        XCTAssertNil(result)
        XCTAssertEqual(editor.chapter?.status, .draft, "chapter must be untouched on failure")
        XCTAssertEqual(editor.chapter?.source, .agent)
        XCTAssertFalse(editor.isImporting, "isImporting must reset even on error")
        XCTAssertEqual(bus.current?.message, "章节当前状态不允许 import")
    }

    // MARK: payload wire format

    /// Locks the contract: `runExtractor` Swift property must encode to
    /// the JSON key `"run_extractor"`. A silent rename would 422 in
    /// production with the user staring at a useless modal.
    func test_importRequest_encodesRunExtractorAsSnakeCase_true() throws {
        let payload = ChapterImportRequest(
            draftText: "x",
            title: nil,
            summary: nil,
            runExtractor: true
        )
        let json = try jsonObject(from: payload)
        XCTAssertEqual(json["run_extractor"] as? Bool, true)
        XCTAssertEqual(json["draft_text"] as? String, "x")
        XCTAssertNil(json["title"])
        XCTAssertNil(json["summary"])
    }

    func test_importRequest_encodesRunExtractorAsSnakeCase_false() throws {
        let payload = ChapterImportRequest(
            draftText: "y",
            title: "T",
            summary: "S",
            runExtractor: false
        )
        let json = try jsonObject(from: payload)
        XCTAssertEqual(json["run_extractor"] as? Bool, false)
        XCTAssertEqual(json["draft_text"] as? String, "y")
        XCTAssertEqual(json["title"] as? String, "T")
        XCTAssertEqual(json["summary"] as? String, "S")
    }

    // MARK: ChaptersStore upsert handoff

    func test_chaptersStore_upsert_afterImport_reflectsImportedBadge() async {
        // The sheet finishes by calling `chaptersStore.upsert(result.chapter)`
        // so the sidebar list sees the `source = .imported` flip. Verify the
        // upsert path produces the right summary shape.
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (book, chapter) = await makeBookAndChapter(mock)
        let chaptersStore = ChaptersStore(api: mock, errorBus: bus)
        await chaptersStore.load(bookId: book.id)
        XCTAssertEqual(chaptersStore.chapters.first?.source, .agent)

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "正文", runExtractor: false)
        )
        XCTAssertNotNil(result)
        chaptersStore.upsert(result!.chapter)

        XCTAssertEqual(chaptersStore.chapters.first?.source, .imported)
        XCTAssertEqual(chaptersStore.chapters.first?.status, .finalized)
    }

    // MARK: helpers

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        // The production `APIClient` uses `CodecFactory.makeEncoder()`. Use
        // the same factory here so the test reflects real wire behaviour
        // (snake_case + ISO8601 date format).
        let encoder = CodecFactory.makeEncoder()
        let data = try encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
