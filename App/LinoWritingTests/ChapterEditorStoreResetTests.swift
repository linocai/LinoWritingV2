import XCTest
@testable import LinoWriting

/// PROJECT_PLAN v0.7 §5.P.1 — frontend §5.P (G + E) coverage.
///
/// Guards two related behaviours that share the same underlying primitive
/// (`resetAllPublishedToIdle`):
///
/// 1. **G — switching chapters wipes every per-chapter @Published.**
///    The bug pre-fix: finalize chapter A → `lastUpdatedCharacterIds` is
///    populated; user clicks chapter B in the sidebar → `load(B)` only
///    cleared `writingState` so the right-panel red dot stayed lit on
///    B's character cards. Lock the contract that load() resets *all*
///    per-chapter flags.
///
/// 2. **E (P-3) — admin_reset escape hatch refreshes both the chapter and
///    the per-chapter flags.** A force-rewritten chapter invalidates any
///    in-flight `isImporting` / streaming buffer / highlight list, so
///    after the rescue everything must read as a fresh load.
@MainActor
final class ChapterEditorStoreResetTests: XCTestCase {

    // MARK: helpers

    private func makeBookAndTwoChapters(_ mock: MockAPIClient) async -> (Book, Chapter, Chapter) {
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapterA = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "A 的想法", title: "A")
        )
        let chapterB = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "B 的想法", title: "B")
        )
        return (book, chapterA, chapterB)
    }

    // MARK: G — load(chapterId:) clears per-chapter @Published

    /// The exact scenario the reviewer flagged: finalize A, switch to B,
    /// expect B's editor to start with an empty `lastUpdatedCharacterIds`
    /// — otherwise the right-panel highlight from A would leak onto B's
    /// character cards even though B has no extractor side-effects yet.
    func test_loadChapter_clearsLastUpdatedCharacterIdsFromPriorChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapterA, chapterB) = await makeBookAndTwoChapters(mock)

        // Get chapter A into the same "draft_ready" preamble that finalize
        // expects (the mock's expand → write pipeline does this for us).
        _ = try? await mock.expand(chapterId: chapterA.id, force: false)
        // Fake out the finalize so it reports updated character ids.
        mock.onFinalize = { id in
            var c = mock.chapters.first { $0.id == id }!
            c.status = .finalized
            c.summary = "summary"
            c.updatedAt = Date()
            if let idx = mock.chapters.firstIndex(where: { $0.id == id }) {
                mock.chapters[idx] = c
            }
            return FinalizeResult(
                chapter: c,
                updatedCharacterIds: ["char-1", "char-2"],
                addedEventIds: []
            )
        }

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapterA.id)
        let finalized = await editor.finalize()
        XCTAssertNotNil(finalized)
        XCTAssertEqual(
            editor.lastUpdatedCharacterIds,
            ["char-1", "char-2"],
            "precondition: finalize must surface ids into the highlight pipe"
        )

        // Now the bug-trigger: user clicks chapter B in the sidebar.
        await editor.load(chapterId: chapterB.id)

        XCTAssertEqual(editor.chapter?.id, chapterB.id)
        XCTAssertTrue(
            editor.lastUpdatedCharacterIds.isEmpty,
            "switching chapters must wipe the prior chapter's highlight ids — "
            + "otherwise the right-panel red dot would leak onto B's cards"
        )
    }

    /// Belt-and-braces variant: every other per-chapter flag is also
    /// wiped. We can't easily drive `isImporting=true` mid-test (the mock
    /// awaits synchronously), but we *can* assert the post-load baseline.
    func test_loadChapter_resetsAllPerChapterPublishedToIdle() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapterA, chapterB) = await makeBookAndTwoChapters(mock)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)

        // Bring up chapter A and finalize so lastUpdatedCharacterIds is non-empty.
        await editor.load(chapterId: chapterA.id)
        _ = await editor.expand()
        mock.onFinalize = { id in
            let c = mock.chapters.first { $0.id == id }!
            return FinalizeResult(
                chapter: c,
                updatedCharacterIds: ["c-1"],
                addedEventIds: []
            )
        }
        _ = await editor.finalize()
        XCTAssertFalse(editor.lastUpdatedCharacterIds.isEmpty)

        // Switch. Every per-chapter flag should be at idle baseline.
        await editor.load(chapterId: chapterB.id)
        XCTAssertEqual(editor.writingState, .idle)
        XCTAssertFalse(editor.isStreaming)
        XCTAssertFalse(editor.isExpanding)
        XCTAssertFalse(editor.isFinalizing)
        XCTAssertFalse(editor.isImporting)
        XCTAssertTrue(editor.lastUpdatedCharacterIds.isEmpty)
    }

    /// `reset()` is the public teardown entrypoint (called from book/
    /// workspace deinit paths). It should be equivalent to a load() with
    /// a chapter that fails to fetch — every flag back to idle plus
    /// `chapter = nil`.
    func test_reset_clearsEverythingIncludingChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapterA, _) = await makeBookAndTwoChapters(mock)
        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapterA.id)
        XCTAssertNotNil(editor.chapter)

        editor.reset()
        XCTAssertNil(editor.chapter)
        XCTAssertEqual(editor.writingState, .idle)
        XCTAssertFalse(editor.isExpanding)
        XCTAssertFalse(editor.isFinalizing)
        XCTAssertFalse(editor.isImporting)
        XCTAssertTrue(editor.lastUpdatedCharacterIds.isEmpty)
    }

    // MARK: E (P-3) — adminReset escape hatch

    func test_adminReset_writingToDraftReady_succeedsAndClearsState() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter, _) = await makeBookAndTwoChapters(mock)
        // Pretend the chapter got stranded mid-stream — backend status
        // is .writing and the local store carries stale highlight ids
        // from an earlier finalize on the same editor instance.
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .writing
            mock.chapters[idx].draftText = "已经写了半段还卡住的正文"
            mock.chapters[idx].structuredPrompt = StructuredPrompt(
                plotAnchors: ["A"],
                charactersInvolved: [],
                chapterStyle: "should be preserved"
            )
        }

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        XCTAssertEqual(editor.chapter?.status, .writing)

        let ok = await editor.adminReset(targetStatus: .draftReady)
        XCTAssertTrue(ok)
        XCTAssertEqual(editor.chapter?.status, .draftReady)
        XCTAssertEqual(
            editor.chapter?.draftText,
            "已经写了半段还卡住的正文",
            "admin_reset must preserve draft_text — that's the whole rescue contract"
        )
        XCTAssertEqual(
            editor.chapter?.structuredPrompt?.chapterStyle,
            "should be preserved",
            "structured_prompt is preserved too"
        )
        XCTAssertTrue(editor.lastUpdatedCharacterIds.isEmpty)
        XCTAssertFalse(editor.isImporting)
        XCTAssertFalse(editor.isFinalizing)
        XCTAssertFalse(editor.isExpanding)
        XCTAssertNil(bus.current)
        XCTAssertTrue(mock.calls.contains("adminResetChapter"))
    }

    /// adminReset is idempotent on the wire — calling it when already at
    /// the target state returns the chapter unchanged. The store should
    /// happily report success in that case too (user double-clicked the
    /// confirm button, or the network retried).
    func test_adminReset_idempotent_returnsTrueAndStaysAtTarget() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter, _) = await makeBookAndTwoChapters(mock)
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .draftReady
        }
        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        let ok = await editor.adminReset(targetStatus: .draftReady)
        XCTAssertTrue(ok)
        XCTAssertEqual(editor.chapter?.status, .draftReady)
    }

    func test_adminReset_networkFailure_publishesAndKeepsChapter() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapter, _) = await makeBookAndTwoChapters(mock)
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .writing
        }
        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        XCTAssertEqual(editor.chapter?.status, .writing)

        mock.errorToThrow = .server("backend 暂时不可用")
        let ok = await editor.adminReset(targetStatus: .draftReady)
        XCTAssertFalse(ok)
        XCTAssertEqual(
            editor.chapter?.status,
            .writing,
            "failed rescue must not silently mutate the local chapter"
        )
        XCTAssertEqual(bus.current?.message, "backend 暂时不可用")
    }

    // MARK: wire format

    /// Lock the snake_case encoding so a future Swift-side rename can't
    /// silently break the contract (the backend would 422 if it sees
    /// `targetStatus` instead of `target_status`).
    func test_adminResetRequest_encodesTargetStatusAsSnakeCase() throws {
        let payload = ChapterAdminResetRequest(targetStatus: .draftReady)
        let encoder = CodecFactory.makeEncoder()
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["target_status"] as? String, "draft_ready")
        XCTAssertNil(json["targetStatus"])
    }

    /// P-2 reviewer 🟡 #4: the prior `…resetsAllPerChapterPublishedToIdle`
    /// test only proved the flags read as `false` when `load()` ran —
    /// which they already do because the sync mock leaves every
    /// defer-managed flag at false by the time the assertion runs. To
    /// truly lock the contract we have to construct a polluted state
    /// (a flag genuinely `true`) and prove `load()` wipes it.
    ///
    /// SSE writing is the only flow in the store with an in-flight
    /// state the test can observe deterministically: `startWriting()`
    /// flips `writingState` to `.streaming` synchronously before yielding
    /// to the Task, and the `MockAPIClient.writeStream` AsyncStream
    /// holds the Task open. From that polluted state, calling
    /// `load(chapterId:)` should cancel the stream and reset
    /// `writingState` back to `.idle` regardless of where the SSE Task
    /// was paused.
    func test_loadChapter_clearsWritingStatePollutedByInflightStream() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let (_, chapterA, chapterB) = await makeBookAndTwoChapters(mock)

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapterA.id)
        // Move A through expand → write_ready so startWriting is allowed.
        _ = try? await mock.expand(chapterId: chapterA.id, force: false)
        await store.load(chapterId: chapterA.id)

        // Pollute writingState via the real SSE path.
        store.startWriting()
        XCTAssertTrue(
            store.isStreaming,
            "isStreaming must be true the moment startWriting() returns"
        )

        // Switch chapters — load() should cancel the stream and reset.
        await store.load(chapterId: chapterB.id)
        XCTAssertEqual(store.chapter?.id, chapterB.id)
        XCTAssertEqual(
            store.writingState,
            .idle,
            "writingState must be reset to .idle when load switches chapters"
        )
        XCTAssertFalse(store.isStreaming)
        XCTAssertFalse(store.isExpanding)
        XCTAssertFalse(store.isFinalizing)
        XCTAssertFalse(store.isImporting)
        XCTAssertFalse(store.isAdminResetting)
    }
}
