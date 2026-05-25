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

    // MARK: - v0.7 §5.O Batch import

    func test_batchCreateAndImport_allSuccess_returnsAllSuccessResults() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = [
            ParsedChapter(index: 0, title: "山洞", body: "山洞里很黑。"),
            ParsedChapter(index: 1, title: "河边", body: "小马喝水。"),
            ParsedChapter(index: 2, title: "村口", body: "夜深。")
        ]

        var progressCalls: [(Int, Int)] = []
        let results = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: true,
            progress: { c, t in progressCalls.append((c, t)) }
        )

        XCTAssertEqual(results.count, 3)
        for result in results {
            if case .failure = result {
                XCTFail("expected all success, got \(result)")
            }
        }
        XCTAssertEqual(store.chapters.count, 3, "sidebar should now show 3 chapters")
        XCTAssertEqual(store.chapters.allSatisfy { $0.source == .imported }, true)
        XCTAssertEqual(store.chapters.allSatisfy { $0.status == .finalized }, true)
        XCTAssertNil(bus.current, "happy path must not publish to the error bus")
    }

    func test_batchCreateAndImport_progressCallback_calledOncePerChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = (0..<5).map {
            ParsedChapter(index: $0, title: "第\($0 + 1)章", body: "正文\($0)")
        }

        var progressCalls: [(Int, Int)] = []
        _ = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: false,
            progress: { c, t in progressCalls.append((c, t)) }
        )

        XCTAssertEqual(progressCalls.count, 5, "progress should be called once per chapter")
        XCTAssertEqual(progressCalls.first?.0, 1, "first call uses 1-based current")
        XCTAssertEqual(progressCalls.last?.0, 5)
        XCTAssertTrue(progressCalls.allSatisfy { $0.1 == 5 },
                      "total should be constant across all calls")
    }

    func test_batchCreateAndImport_middleFailure_continuesAndRecordsFailure() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = (0..<3).map {
            ParsedChapter(index: $0, title: "第\($0 + 1)章", body: "正文\($0)")
        }

        // Fail the 2nd chapter's import specifically. The mock's onImport
        // closure receives `(id, payload)`; chapter id #2 maps to the
        // 2nd parsed chapter because we create them in order. We don't
        // know that id ahead of time, so use the body text to detect.
        mock.onImport = { id, payload in
            if payload.draftText == "正文1" {
                throw AppError.upstream("模拟 LLM 429", retryable: true)
            }
            // Default success — mirror MockAPIClient's stock body.
            // We can't reach the original closure-free path through the
            // mock when onImport is set, so reconstruct it here.
            let now = Date()
            let updated = Chapter(
                id: id,
                bookId: book.id,
                index: 0,
                title: payload.title,
                draftText: payload.draftText,
                status: .finalized,
                source: .imported,
                createdAt: now,
                updatedAt: now
            )
            return ChapterImportResponse(
                chapter: updated,
                updatedCharacterIds: [],
                addedEventIds: []
            )
        }

        let results = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: true,
            progress: { _, _ in }
        )

        XCTAssertEqual(results.count, 3, "all 3 should be attempted even after failure")
        guard case .success = results[0] else { return XCTFail("ch 0 should succeed") }
        guard case .failure(let err) = results[1] else { return XCTFail("ch 1 should fail") }
        guard case .success = results[2] else { return XCTFail("ch 2 should succeed") }
        XCTAssertEqual(err.message, "模拟 LLM 429")
        XCTAssertNil(bus.current,
                     "batch should NOT publish per-chapter failures to ErrorBus — the sheet aggregates")
    }

    /// Importantly: a per-chapter failure must **not** abort the loop.
    /// Verify by checking that all 3 progress callbacks fire even with
    /// the middle one failing.
    func test_batchCreateAndImport_failureDoesNotShortCircuitProgress() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = (0..<3).map {
            ParsedChapter(index: $0, title: "T\($0)", body: "正文\($0)")
        }

        mock.onImport = { id, payload in
            if payload.draftText == "正文1" {
                throw AppError.upstream("boom", retryable: false)
            }
            let now = Date()
            return ChapterImportResponse(
                chapter: Chapter(
                    id: id,
                    bookId: book.id,
                    index: 0,
                    title: payload.title,
                    draftText: payload.draftText,
                    status: .finalized,
                    source: .imported,
                    createdAt: now,
                    updatedAt: now
                ),
                updatedCharacterIds: [],
                addedEventIds: []
            )
        }

        var progress: [(Int, Int)] = []
        _ = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: false,
            progress: { c, t in progress.append((c, t)) }
        )

        XCTAssertEqual(progress.count, 3)
        XCTAssertEqual(progress.map { $0.0 }, [1, 2, 3],
                       "progress current must advance even past a failed chapter")
    }

    /// Serial execution: each chapter's `createChapter` must complete
    /// before the next chapter's begins. Verify by ordering of the
    /// recorded calls on the mock — `createChapter` for chapter N
    /// must happen before `createChapter` for chapter N+1.
    func test_batchCreateAndImport_runsSequentially() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = (0..<4).map {
            ParsedChapter(index: $0, title: "T\($0)", body: "B\($0)")
        }

        // Snapshot pre-batch calls so we measure only what the batch run added.
        let preCount = mock.calls.count
        _ = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: false,
            progress: { _, _ in }
        )
        let batchCalls = Array(mock.calls[preCount...])

        // Expected sequence: createChapter, importChapter, createChapter,
        // importChapter, … (× 4). If anything ran in parallel the calls
        // would interleave differently.
        let expected = ["createChapter", "importChapter",
                        "createChapter", "importChapter",
                        "createChapter", "importChapter",
                        "createChapter", "importChapter"]
        XCTAssertEqual(batchCalls, expected,
                       "calls must alternate strictly create→import per chapter")
    }

    func test_batchCreateAndImport_emptyInput_returnsEmpty() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        var progressCalled = false
        let results = await store.batchCreateAndImport(
            parsedChapters: [],
            runExtractor: true,
            progress: { _, _ in progressCalled = true }
        )

        XCTAssertEqual(results.count, 0)
        XCTAssertFalse(progressCalled, "no chapters → no progress callbacks")
        XCTAssertEqual(store.chapters.count, 0)
    }

    func test_batchCreateAndImport_runExtractorFlag_propagatesToPayload() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let store = ChaptersStore(api: mock, errorBus: bus)
        await store.load(bookId: book.id)

        let parsed = [ParsedChapter(index: 0, title: "T", body: "B")]

        _ = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: false,
            progress: { _, _ in }
        )
        XCTAssertEqual(mock.lastImportPayload?.runExtractor, false)

        _ = await store.batchCreateAndImport(
            parsedChapters: parsed,
            runExtractor: true,
            progress: { _, _ in }
        )
        XCTAssertEqual(mock.lastImportPayload?.runExtractor, true)
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
