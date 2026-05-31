import XCTest
@testable import LinoWriting

/// Coverage for the v0.9.3 §5.DI import/extract decoupling:
///   - `ChapterEditorStore.extract()` happy + failure paths (DI-3).
///   - The `submitImport` failure-rollback contract: when the import call
///     fails, the step-1 skeleton chapter must be deleted and the editor
///     reset so the author isn't stranded on a blank new-chapter SOP (DI-2).
@MainActor
final class ChapterExtractTests: XCTestCase {

    // MARK: helpers

    private func makeBookAndFinalizedChapter(
        _ mock: MockAPIClient
    ) async -> (Book, Chapter) {
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "", title: "已落地章节")
        )
        // Drive it to a finalized state with draft_text (import contract) so
        // extract has something to operate on, mirroring the real flow.
        _ = try! await mock.importChapter(
            id: chapter.id,
            payload: ChapterImportRequest(draftText: "已经写好的整章正文。", runExtractor: false)
        )
        let finalized = try! await mock.getChapter(id: chapter.id)
        return (book, finalized)
    }

    // MARK: extract() happy path

    func test_extract_success_writesChapterAndHighlights() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (book, chapter) = await makeBookAndFinalizedChapter(mock)

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        XCTAssertEqual(editor.chapter?.status, .finalized)
        XCTAssertFalse(editor.isExtracting)

        // Simulate the Extractor touching two characters + adding an event.
        mock.onExtract = { id in
            let now = Date()
            let updated = Chapter(
                id: id,
                bookId: book.id,
                index: chapter.index,
                title: chapter.title,
                draftText: chapter.draftText,
                status: .finalized,        // extract never changes status
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

        let result = await editor.extract()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.updatedCharacterIds, ["c1", "c2"])
        XCTAssertEqual(result?.addedEventIds, ["e1"])
        // extract reuses the same highlight pipe as finalize/import.
        XCTAssertEqual(editor.lastUpdatedCharacterIds, ["c1", "c2"])
        // Chapter stays finalized — extract doesn't reopen / change status.
        XCTAssertEqual(editor.chapter?.status, .finalized)
        XCTAssertFalse(editor.isExtracting, "isExtracting must reset after success")
        XCTAssertNil(bus.current, "happy path must not publish to the error bus")
        XCTAssertEqual(mock.calls.last, "extractChapter")
    }

    // MARK: extract() failure path

    func test_extract_failure_publishesAndKeepsChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter) = await makeBookAndFinalizedChapter(mock)

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        let before = editor.chapter

        // Simulate the backend's 409 "no draft to extract" / upstream LLM error.
        mock.onExtract = { _ in
            throw AppError.upstream("模拟提取失败", retryable: true)
        }

        let result = await editor.extract()

        XCTAssertNil(result)
        XCTAssertEqual(editor.chapter?.status, before?.status,
                       "chapter must be untouched on extract failure")
        XCTAssertEqual(editor.chapter?.draftText, before?.draftText)
        XCTAssertFalse(editor.isExtracting, "isExtracting must reset even on error")
        XCTAssertEqual(bus.current?.message, "模拟提取失败")
    }

    func test_extract_noChapterLoaded_returnsNil() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        let result = await editor.extract()

        XCTAssertNil(result)
        XCTAssertFalse(editor.isExtracting)
        XCTAssertFalse(mock.calls.contains("extractChapter"),
                       "extract must short-circuit when no chapter is loaded")
    }

    // MARK: isExtracting reset on chapter switch

    func test_loadChapter_resetsIsExtracting() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter) = await makeBookAndFinalizedChapter(mock)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        await editor.load(chapterId: chapter.id)
        XCTAssertFalse(editor.isExtracting)
        // reset() routes through resetAllPublishedToIdle(), which must clear
        // isExtracting alongside the other per-chapter flags.
        editor.reset()
        XCTAssertFalse(editor.isExtracting)
        XCTAssertNil(editor.chapter)
    }

    // MARK: extractChapter wire path (no body, finalized envelope)

    func test_extractChapter_mockDefault_returnsImportEnvelopeUnchanged() async throws {
        let mock = MockAPIClient()
        let (_, chapter) = await makeBookAndFinalizedChapter(mock)

        // Default mock (no onExtract hook): returns the chapter unchanged with
        // empty id arrays — mirrors the backend leaving the row alone.
        let resp = try await mock.extractChapter(id: chapter.id)
        XCTAssertEqual(resp.chapter.id, chapter.id)
        XCTAssertEqual(resp.chapter.status, .finalized)
        XCTAssertEqual(resp.updatedCharacterIds, [])
        XCTAssertEqual(resp.addedEventIds, [])
    }

    // MARK: DI-2 submitImport failure rollback (store-level contract)

    /// Replicates `NewChapterSheet.submitImport`'s sequence at the store
    /// layer: create skeleton → import fails → the sheet deletes the skeleton
    /// and resets the editor. Verifies the stranded empty chapter is gone so
    /// the author isn't dumped into a blank new-chapter SOP with body lost.
    func test_submitImport_failure_deletesSkeletonChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))

        let chaptersStore = ChaptersStore(api: mock, errorBus: bus)
        await chaptersStore.load(bookId: book.id)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        // Step 1: create skeleton (same as submitImport).
        let new = await chaptersStore.create(userPrompt: "", title: "导入章")
        XCTAssertNotNil(new)
        XCTAssertEqual(chaptersStore.chapters.count, 1, "skeleton appended to sidebar")
        await editor.load(chapterId: new!.id)

        // Step 2: import fails (transport-only now that run_extractor=false).
        mock.onImport = { _, _ in
            throw AppError.transport("网络中断")
        }
        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "正文", runExtractor: false)
        )
        XCTAssertNil(result, "import must fail")

        // Step 3: the sheet's rollback — delete skeleton + reset editor.
        await chaptersStore.delete(id: new!.id)
        editor.reset()

        XCTAssertEqual(chaptersStore.chapters.count, 0,
                       "stranded skeleton must be removed from the sidebar")
        XCTAssertNil(editor.chapter, "editor must be cleared after rollback")
        XCTAssertEqual(bus.current?.message, "网络中断")
    }

    /// Reviewer 🟡#2 lock: `ChaptersStore.create()` must NOT flip
    /// `showNewChapterSheet` to false as a side effect. `submitImport` builds a
    /// skeleton via `create()` as step 1; if the import then fails the sheet
    /// must stay OPEN so the already-pasted body in the sheet's `@State` survives
    /// for retry. The old `showNewChapterSheet = false` in `create()` started
    /// tearing the sheet down at step 1, defeating the failure-path retry.
    func test_create_doesNotCloseNewChapterSheet_onImportFailureSequence() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))

        let chaptersStore = ChaptersStore(api: mock, errorBus: bus)
        await chaptersStore.load(bookId: book.id)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        // The sheet is open (the user is in the new-chapter SOP).
        chaptersStore.showNewChapterSheet = true

        // Step 1: create skeleton. This must NOT close the sheet.
        let new = await chaptersStore.create(userPrompt: "", title: "导入章")
        XCTAssertNotNil(new)
        XCTAssertTrue(chaptersStore.showNewChapterSheet,
                      "create() must not flip showNewChapterSheet — closing is the caller's job")
        await editor.load(chapterId: new!.id)

        // Step 2: import fails.
        mock.onImport = { _, _ in throw AppError.transport("网络中断") }
        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "正文", runExtractor: false)
        )
        XCTAssertNil(result, "import must fail")

        // Step 3: the sheet's rollback deletes the skeleton + resets the editor,
        // but does NOT dismiss — the sheet stays open for retry.
        await chaptersStore.delete(id: new!.id)
        editor.reset()

        XCTAssertTrue(chaptersStore.showNewChapterSheet,
                      "sheet must remain open after a failed import so the pasted body survives")
    }

    func test_submitImport_success_keepsChapterNoRollback() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))

        let chaptersStore = ChaptersStore(api: mock, errorBus: bus)
        await chaptersStore.load(bookId: book.id)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        let new = await chaptersStore.create(userPrompt: "", title: "导入章")
        await editor.load(chapterId: new!.id)
        let result = await editor.importChapter(
            ChapterImportRequest(draftText: "用户正文", runExtractor: false)
        )
        XCTAssertNotNil(result)
        chaptersStore.upsert(result!.chapter)

        XCTAssertEqual(chaptersStore.chapters.count, 1)
        XCTAssertEqual(chaptersStore.chapters.first?.status, .finalized)
        XCTAssertEqual(chaptersStore.chapters.first?.source, .imported)
        // The mock records the payload — confirm run_extractor=false survived.
        XCTAssertEqual(mock.lastImportPayload?.runExtractor, false)
    }
}
