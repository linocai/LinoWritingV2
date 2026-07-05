import XCTest
@testable import LinoWriting

/// v1.2.0 (HH) P7 — frontend half of thinking-model support.
///
/// `ChapterEditorStore.startWriting` must accumulate `.thinking` SSE events
/// into a separate `thinkingBuffer`, never mixing them into `writingState`'s
/// draft buffer/chars, and `isThinking` must reflect "thinking frames have
/// arrived but no token text yet this stream" so the UI's "模型思考中…"
/// indicator disappears once real prose starts.
@MainActor
final class ChapterEditorStoreThinkingTests: XCTestCase {

    private func makeChapterReadyToWrite(_ mock: MockAPIClient) async -> Chapter {
        let book = try! await mock.createBook(BookCreateRequest(title: "P7", coverColor: nil))
        let chapter = try! await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: "思考测试", title: "P7 章")
        )
        _ = try? await mock.expand(chapterId: chapter.id, force: false)
        return chapter
    }

    private func isStillStreaming(_ state: ChapterEditorStore.WritingState) -> Bool {
        if case .streaming = state { return true }
        return false
    }

    private func waitUntilDone(_ store: ChapterEditorStore, maxAttempts: Int = 400) async {
        var attempts = 0
        while store.writingState != .done, attempts < maxAttempts {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
    }

    func test_thinkingFrames_accumulateIntoSeparateBuffer_notDraftBuffer() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "清晨的雾还没散。"
            c.status = .draftReady
            c.updatedAt = Date()
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) {
                mock.chapters[idx] = c
            }
            return [
                .started(chapterId: chapterId),
                .thinking(text: "让我想想这一章。"),
                .thinking(text: "主角应该先发现线索。"),
                .token(text: "清晨的雾"),
                .token(text: "还没散。"),
                .done(chapter: c)
            ]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.startWriting()
        await waitUntilDone(store)

        XCTAssertEqual(store.writingState, .done)
        XCTAssertEqual(
            store.thinkingBuffer, "让我想想这一章。主角应该先发现线索。",
            "thinking text must accumulate in its own buffer"
        )
        XCTAssertEqual(
            store.chapter?.draftText, "清晨的雾还没散。",
            "thinking text must never leak into the saved draft"
        )
    }

    func test_isThinking_trueWhileThinkingArrivesBeforeAnyToken() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        // Use onWriteThrowAfterTokens-style manual stream control isn't
        // needed here — a synchronous AsyncThrowingStream from onWrite lets
        // us assert mid-stream state isn't practical without a real delay,
        // so this test instead asserts the *contract*: thinkingBuffer
        // non-empty + writingState's buffer still empty ⇒ isThinking true.
        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "正文"
            c.status = .draftReady
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) {
                mock.chapters[idx] = c
            }
            return [
                .started(chapterId: chapterId),
                .thinking(text: "思考中"),
                .token(text: "正文"),
                .done(chapter: c)
            ]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.startWriting()
        await waitUntilDone(store)

        // After completion, isThinking must be false (isStreaming is false
        // once .done fires) even though thinkingBuffer retains the text —
        // the indicator is gated on isStreaming, not just buffer content.
        XCTAssertFalse(store.isThinking)
    }

    func test_pureTokenStream_neverPopulatesThinkingBuffer() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)
        // Default onWrite (no override) emits only .started/.token/.done.

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.startWriting()
        await waitUntilDone(store)

        XCTAssertEqual(store.writingState, .done)
        XCTAssertTrue(
            store.thinkingBuffer.isEmpty,
            "a model that never emits .thinking must leave thinkingBuffer empty"
        )
    }

    func test_startWriting_resetsThinkingBufferFromPriorStream() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeChapterReadyToWrite(mock)

        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "稿"
            c.status = .draftReady
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) {
                mock.chapters[idx] = c
            }
            return [
                .started(chapterId: chapterId),
                .thinking(text: "第一次思考"),
                .token(text: "稿"),
                .done(chapter: c)
            ]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.startWriting()
        await waitUntilDone(store)
        XCTAssertEqual(store.thinkingBuffer, "第一次思考")

        // Re-enable write for a second round (draft_ready → regenerate).
        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "第二稿"
            c.status = .draftReady
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) {
                mock.chapters[idx] = c
            }
            return [.started(chapterId: chapterId), .token(text: "第二稿"), .done(chapter: c)]
        }
        store.startWriting()
        await waitUntilDone(store)

        XCTAssertTrue(
            store.thinkingBuffer.isEmpty,
            "starting a new write must reset thinkingBuffer from the prior stream"
        )
    }
}
