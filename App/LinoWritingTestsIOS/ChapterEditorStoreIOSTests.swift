import XCTest
import UIKit
@testable import LinoWriting

/// R-4 (v0.8) — iOS-runtime confirmation that ``ChapterEditorStore`` runs
/// the same draft → prompt-ready → draft-ready → finalized flow under the
/// iOS Simulator. The macOS bundle has a richer set
/// (`ChapterEditorStoreResetTests`, `StoreTests`); this iOS pass focuses
/// on the three "must work on iPhone too" transitions plus the reset
/// guard that R-3's `leaveWorkspace()` depends on.
@MainActor
final class ChapterEditorStoreIOSTests: XCTestCase {

    func test_load_setsChapterFromBackend() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        XCTAssertEqual(editor.chapter?.id, chapter.id)
        XCTAssertEqual(editor.chapter?.status, .draft)
        XCTAssertEqual(editor.writingState, .idle)
    }

    func test_expand_transitionsToPromptReady() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        let expanded = await editor.expand()

        XCTAssertEqual(expanded?.status, .promptReady)
        XCTAssertNotNil(editor.chapter?.structuredPrompt)
    }

    func test_startWriting_streamsTokensAndCompletes() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        await withCheckedContinuation { continuation in
            editor.startWriting { _ in continuation.resume() }
        }

        XCTAssertEqual(editor.chapter?.status, .draftReady)
        XCTAssertEqual(editor.writingState, .done)
    }

    func test_reset_clearsAllStateForLeaveWorkspace() async {
        // R-3 / R-1 — leaveWorkspace() calls store.reset() on iPhone when
        // the user taps "书架" in the NavStack toolbar. Confirm reset()
        // wipes both the chapter and the writingState so the next book
        // doesn't see stale data when reopened.
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)
        XCTAssertNotNil(editor.chapter)

        editor.reset()

        XCTAssertNil(editor.chapter)
        XCTAssertEqual(editor.writingState, .idle)
    }

    // MARK: - v1.3.1 (KK) P5 — iOS screen-sleep-during-streaming fix

    /// The idle timer must be disabled for the duration of an SSE write and
    /// restored the moment it completes — the structural `writingState`
    /// `didSet` (not a per-call-site point-name) is what drives this, so
    /// this test exercises the store's public API exactly like a real
    /// screen would, rather than reaching into the private toggle directly.
    func test_startWriting_disablesIdleTimerDuringStream_restoresOnDone() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        // Baseline: nothing streaming yet, idle timer must be the normal
        // "allowed to sleep" default.
        UIApplication.shared.isIdleTimerDisabled = false

        await withCheckedContinuation { continuation in
            editor.startWriting { _ in continuation.resume() }
        }

        // `startWriting`'s completion callback fires from the `.done` case,
        // which is the same tick `writingState` flips to `.done` — the
        // `didSet`-driven `endStreamingProtection()` has already run by the
        // time we get here, so the idle timer should already be restored.
        XCTAssertEqual(editor.writingState, .done)
        XCTAssertFalse(
            UIApplication.shared.isIdleTimerDisabled,
            "idle timer must be re-enabled once writingState leaves .streaming"
        )
    }

    /// v1.3.2 (LL) P2 — "停止生成" (`stopWriting`) is the exit path the plan
    /// calls out (replacing the old `cancelStream`). Confirm the state-source-
    /// driven idle-timer fix covers it: once `writingState` leaves `.streaming`
    /// (after the async cancel round-trip settles), the idle timer is restored.
    func test_stopWriting_restoresIdleTimer() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        UIApplication.shared.isIdleTimerDisabled = false
        editor.startWriting()
        // `startWriting` sets `writingState = .streaming(...)` synchronously
        // before kicking off the SSE task, so the idle-timer disable has
        // already happened by the time this call returns.
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        editor.stopWriting()  // detaches + async POST /write/cancel → settles to .idle
        // Poll until writingState leaves .streaming (bounded so a regression
        // fails fast instead of hanging).
        for _ in 0..<400 {
            if case .streaming = editor.writingState {
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                break
            }
        }

        if case .streaming = editor.writingState {
            XCTFail("stopWriting must leave the .streaming state")
        }
        XCTAssertFalse(
            UIApplication.shared.isIdleTimerDisabled,
            "idle timer must be re-enabled once writingState leaves .streaming"
        )
    }

    // MARK: - v1.4.0 (MM) P4 — revising treated as busy for the idle-timer guard

    /// (🔵9) `updateStreamingSideEffects` must treat `.revising` exactly like
    /// `.streaming` for the screen-sleep guard — a standalone `revise()`'s
    /// (up to 300s) compression call must not let the phone sleep either.
    func test_revise_disablesIdleTimerDuringRevising_restoresOnDone() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let book = try! await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        var chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "想法", title: nil)
        )
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = .draftReady
            mock.chapters[idx].draftText = "已有草稿。"
            chapter = mock.chapters[idx]
        }

        let editor = ChapterEditorStore(api: mock, errorBus: bus)
        await editor.load(chapterId: chapter.id)

        UIApplication.shared.isIdleTimerDisabled = false
        editor.revise()
        // `revise()` sets writingState = .revising(...) synchronously before
        // kicking off the SSE task — same shape as `startWriting`'s
        // synchronous `.streaming` transition (see the test above).
        XCTAssertTrue(
            UIApplication.shared.isIdleTimerDisabled,
            "idle timer must be disabled while revising, same as while streaming"
        )

        for _ in 0..<400 {
            if editor.isRevising {
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                break
            }
        }

        XCTAssertEqual(editor.writingState, .done)
        XCTAssertFalse(
            UIApplication.shared.isIdleTimerDisabled,
            "idle timer must be re-enabled once revising settles to done"
        )
    }
}
