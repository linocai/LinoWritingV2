import XCTest
@testable import LinoWriting

/// v1.2.0 (HH) P5 — frontend half of the "断流落稿" fix.
///
/// `ChapterEditorStore.startWriting`'s catch clauses used to fall straight
/// to `.failed` on any thrown error, even when the stream had already
/// produced tokens (`writingState == .streaming`). That meant the backend's
/// P5 partial-draft save (prompt_ready + partial parts → draft_ready) was
/// never discovered by the client — the author saw a hard failure and had
/// to manually reopen the chapter to find their half-written draft. The fix:
/// on a genuine disconnect (not `.cancelled`) while `.streaming`, do the same
/// GET-and-reconcile `refreshAfterIncompleteStream` already does for the
/// graceful "stream ended without done" path.
@MainActor
final class ChapterEditorStorePartialDraftTests: XCTestCase {

    private func makeChapterReadyToWrite(_ mock: MockAPIClient) async -> Chapter {
        let book = try! await mock.createBook(BookCreateRequest(title: "P5", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "断流测试", title: "P5 章")
        )
        _ = try? await mock.expand(chapterId: chapter.id, force: false)
        return chapter
    }

    /// The disconnect scenario: stream yields tokens then throws a
    /// transport-level error (not a graceful `.error` SSE frame). Backend
    /// GET now returns `draft_ready` + non-empty draft_text (mirrors the
    /// backend's P5 partial save) — the store must reconcile to `.done`,
    /// not fall to `.failed`.
    func test_startWriting_transportDisconnectMidStream_reconcilesToDoneWhenBackendSavedPartialDraft() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        mock.onWriteThrowAfterTokens = (
            tokens: ["半", "截", "正文"],
            error: AppError.transport("Connection lost")
        )
        // Simulate the backend's P5 save: GET now returns the partial draft.
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .draftReady
            mock.chapters[idx].draftText = "半截正文"
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.startWriting()
        // Poll until the streamTask's catch clause + refresh finish.
        await waitUntilSettled(store)

        XCTAssertEqual(
            store.writingState, .done,
            "backend saved a partial draft (draft_ready) — the store must reconcile to .done, not .failed"
        )
        XCTAssertEqual(store.chapter?.status, .draftReady)
        XCTAssertEqual(store.chapter?.draftText, "半截正文")
    }

    /// If the GET-after-disconnect itself fails (or the chapter still shows
    /// no usable draft), `refreshAfterIncompleteStream` falls back to
    /// `.failed` — the store must not silently mask a real failure.
    func test_startWriting_transportDisconnect_getFails_fallsBackToFailed() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        mock.onWriteThrowAfterTokens = (
            tokens: ["半", "截"],
            error: AppError.transport("Connection lost")
        )

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.startWriting()
        // After the write stream throws, make the follow-up GET fail too.
        mock.errorToThrow = .server("backend 暂时不可用")

        await waitUntilSettled(store)

        if case .failed = store.writingState {
            // Expected.
        } else {
            XCTFail("expected .failed when the reconcile GET also fails, got \(store.writingState)")
        }
    }

    /// v1.2.0 (HH) 审后修复 🔴#1: the GET-after-disconnect can also succeed
    /// while the chapter still shows no usable draft (backend never reached
    /// the P5 partial-draft save — e.g. the disconnect happened before any
    /// token was even persisted, or the failure was a pre-stream HTTP error
    /// like 401/409/429/5xx thrown before the loop produced a single token).
    /// The store must NOT promote to `.done` just because the GET itself
    /// succeeded — it must maintain `.failed(originalError)` and publish to
    /// the ErrorBus so the failure stays visible.
    func test_startWriting_transportDisconnect_getSucceedsButNoDraft_fallsBackToFailedAndPublishes() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        let originalError = AppError.transport("Connection lost")
        mock.onWriteThrowAfterTokens = (tokens: ["半"], error: originalError)
        // Deliberately do NOT flip the chapter to draft_ready / set draftText —
        // the GET below will succeed but return a chapter with no usable draft.

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.startWriting()
        await waitUntilSettled(store)

        if case .failed(let error) = store.writingState {
            XCTAssertEqual(error, originalError, "must surface the original disconnect error, not a generic one")
        } else {
            XCTFail("expected .failed when GET succeeds but chapter has no usable draft, got \(store.writingState)")
        }
        XCTAssertEqual(bus.current?.message, originalError.message, "ErrorBus must be published so the failure is visible via Toast")
    }

    /// A user-initiated cancel (`.cancelled`) must NOT trigger the
    /// reconcile-GET path — `cancelStream()` already handles that
    /// deterministically by flipping `writingState` to `.idle` before the
    /// task even gets a chance to observe `.cancelled` at the `for try
    /// await` boundary in most cases; but if a `.cancelled` AppError were
    /// ever thrown from the stream itself, the catch clause must still
    /// respect the "no reconcile on user-cancel" rule.
    func test_startWriting_cancelledError_doesNotTriggerReconcile() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        mock.onWriteThrowAfterTokens = (
            tokens: ["部分"],
            error: AppError.cancelled
        )
        // Even if GET would report a saved draft, .cancelled must skip the
        // reconcile path entirely and go straight to .failed with no
        // ErrorBus publish (matches pre-existing .cancelled contract).
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .draftReady
            mock.chapters[idx].draftText = "部分"
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        let getChapterCallsBeforeWrite = mock.calls.filter { $0 == "getChapter" }.count

        store.startWriting()
        await waitUntilSettled(store)

        if case .failed(let error) = store.writingState {
            XCTAssertEqual(error, .cancelled)
        } else {
            XCTFail("expected .failed(.cancelled), got \(store.writingState)")
        }
        let getChapterCallsAfterWrite = mock.calls.filter { $0 == "getChapter" }.count
        XCTAssertEqual(
            getChapterCallsAfterWrite, getChapterCallsBeforeWrite,
            ".cancelled must not trigger the reconcile GET"
        )
        XCTAssertNil(bus.current, ".cancelled must not publish to the ErrorBus")
    }

    private func isStillStreaming(_ state: ChapterEditorStore.WritingState) -> Bool {
        if case .streaming = state { return true }
        return false
    }

    /// Polls `store.writingState` off `.streaming` with a hard cap so a
    /// regression that leaves the state machine stuck fails fast instead of
    /// hanging the test run indefinitely.
    private func waitUntilSettled(_ store: ChapterEditorStore, maxAttempts: Int = 400) async {
        var attempts = 0
        while isStillStreaming(store.writingState), attempts < maxAttempts {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
    }
}
