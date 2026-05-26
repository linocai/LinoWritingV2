import XCTest
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
}
