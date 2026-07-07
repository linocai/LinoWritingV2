import XCTest
@testable import LinoWriting

/// v1.3.2 (LL) P2 — writing-as-a-job frontend state machine:
///   - `stopWriting()` is the only path that cancels the backend job;
///   - `detach()` (chapter switch / teardown) must NOT cancel it;
///   - `reattachWriting()` consumes the `snapshot` replay + tail;
///   - `load()` on a `writing` chapter auto-reattaches;
///   - the cancel endpoint's two returns (settled row vs still-`writing`) are
///     both handled;
///   - reattach control signals (`stranded_write` / `no_active_write`) drive
///     the right terminal (failure Toast vs silent idle).
@MainActor
final class ChapterEditorStoreReattachTests: XCTestCase {

    private func makeReadyChapter(_ mock: MockAPIClient, status: ChapterStatus = .promptReady) async -> Chapter {
        let book = try! await mock.createBook(BookCreateRequest(title: "P2", coverColor: nil))
        var chapter = try! await mock.createChapter(
            bookId: book.id, ChapterCreateRequest(userPrompt: "重连测试", title: "P2 章")
        )
        _ = try? await mock.expand(chapterId: chapter.id, force: false)
        if let idx = mock.chapters.firstIndex(where: { $0.id == chapter.id }) {
            mock.chapters[idx].status = status
            chapter = mock.chapters[idx]
        }
        return chapter
    }

    private func waitUntilSettled(_ store: ChapterEditorStore, maxAttempts: Int = 800) async {
        for _ in 0..<maxAttempts {
            if case .streaming = store.writingState {
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
    }

    /// Poll until `condition` holds (bounded). Used where there's no `.streaming`
    /// phase to key off (e.g. `stopWriting` invoked from an idle state in tests).
    private func waitUntil(maxAttempts: Int = 800, _ condition: () -> Bool) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: stopWriting vs detach

    func test_stopWriting_callsCancelEndpoint() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.startWriting()
        store.stopWriting()
        await waitUntilSettled(store)

        XCTAssertTrue(mock.calls.contains("cancelWrite"), "stopWriting must call POST /write/cancel")
    }

    func test_switchingChapters_doesNotCancelBackendWrite() async {
        // Switching chapters (load → resetAllPublishedToIdle → detach) must NOT
        // cancel the backend job — the whole point of writing-as-a-job.
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let a = await makeReadyChapter(mock)
        let b = await makeReadyChapter(mock)
        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: a.id)

        store.startWriting()
        await store.load(chapterId: b.id)  // switch away mid-write

        XCTAssertFalse(mock.calls.contains("cancelWrite"), "switching chapters must never cancel the backend write")
        XCTAssertEqual(store.chapter?.id, b.id)
    }

    // MARK: reattach snapshot + tail

    func test_reattachWriting_consumesSnapshotThenTailToDone() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)  // prompt_ready → load won't auto-reattach
        var doneChapter = chapter
        doneChapter.status = .draftReady
        doneChapter.draftText = "重连补发的前半段续写到底。"
        mock.onReattach = { id in
            [
                .started(chapterId: id),
                .snapshot(buffer: "重连补发的前半段", chars: 8),
                .token(text: "续写到底。"),
                .done(chapter: doneChapter),
            ]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.reattachWriting()
        await waitUntilSettled(store)

        XCTAssertEqual(store.writingState, .done)
        XCTAssertEqual(store.chapter?.status, .draftReady)
        XCTAssertEqual(store.chapter?.draftText, "重连补发的前半段续写到底。")
        XCTAssertTrue(mock.calls.contains("reattachWriteStream"))
    }

    // MARK: load auto-reattach

    func test_load_writingChapter_autoReattaches() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .writing)
        var doneChapter = chapter
        doneChapter.status = .draftReady
        doneChapter.draftText = "自动重连拿到的完整稿。"
        mock.onReattach = { id in
            [.started(chapterId: id), .snapshot(buffer: "", chars: 0), .done(chapter: doneChapter)]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)  // status == .writing → auto reattach
        await waitUntilSettled(store)

        XCTAssertTrue(mock.calls.contains("reattachWriteStream"), "loading a writing chapter must auto-reattach")
        XCTAssertEqual(store.writingState, .done)
        XCTAssertEqual(store.chapter?.draftText, "自动重连拿到的完整稿。")
    }

    // MARK: cancel endpoint two returns

    func test_stopWriting_returnsSettledRow_goesIdle() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        mock.onCancelWrite = { id in
            var c = mock.chapters.first(where: { $0.id == id })!
            c.status = .draftReady
            c.draftText = "取消时保守落稿。"
            return c
        }
        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.stopWriting()
        await waitUntil { store.chapter?.status == .draftReady }

        XCTAssertEqual(store.writingState, .idle)
        XCTAssertEqual(store.chapter?.status, .draftReady)
        XCTAssertFalse(mock.calls.contains("reattachWriteStream"), "settled cancel row must not need reattach")
    }

    func test_stopWriting_returnsStillWriting_keepsReattaching() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        // Cancel returned before the worker wound down → still `writing`.
        mock.onCancelWrite = { id in
            var c = mock.chapters.first(where: { $0.id == id })!
            c.status = .writing
            return c
        }
        var doneChapter = chapter
        doneChapter.status = .draftReady
        doneChapter.draftText = "收尾后的稿。"
        mock.onReattach = { id in [.started(chapterId: id), .done(chapter: doneChapter)] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.stopWriting()
        await waitUntil { mock.calls.contains("reattachWriteStream") }

        XCTAssertTrue(mock.calls.contains("reattachWriteStream"), "still-writing cancel return must keep reattaching")
    }

    // MARK: reattach control signals

    func test_reattach_strandedWrite_failsAndPublishes() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        mock.onReattach = { id in [.started(chapterId: id), .reattachStranded] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.reattachWriting()
        await waitUntilSettled(store)

        if case .failed = store.writingState {} else {
            XCTFail("stranded_write must land .failed, got \(store.writingState)")
        }
        XCTAssertNotNil(bus.current, "stranded_write must publish a Toast pointing to 强制重置")
    }

    func test_reattach_noActiveWrite_silentlyIdle() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        mock.onReattach = { id in [.started(chapterId: id), .reattachNoActive] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.reattachWriting()
        await waitUntilSettled(store)

        XCTAssertEqual(store.writingState, .idle, "no_active_write must silently drop to idle")
        XCTAssertNil(bus.current, "no_active_write must NOT publish a Toast")
    }

    // MARK: 审后修复 #2 — stopWriting cross-chapter guard

    func test_stopWriting_lateCancelResponse_afterChapterSwitch_isDiscarded() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let a = await makeReadyChapter(mock)
        let b = await makeReadyChapter(mock)
        // Cancel(A) returns a distinctive draft_ready row, but only after a delay
        // long enough for us to switch to B first.
        mock.cancelWriteDelayNanos = 250_000_000
        mock.onCancelWrite = { id in
            var c = mock.chapters.first(where: { $0.id == id })!
            c.status = .draftReady
            c.draftText = "A 的取消稿——绝不能盖到 B 上"
            return c
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: a.id)
        store.stopWriting()               // in-flight cancel for A (delayed)
        await store.load(chapterId: b.id) // switch to B before A's cancel returns

        // Wait past the cancel delay so A's response definitely lands.
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(store.chapter?.id, b.id, "the late cancel(A) response must not replace the current chapter B")
        XCTAssertNotEqual(store.chapter?.draftText, "A 的取消稿——绝不能盖到 B 上")
    }

    // MARK: 审后修复 #3 — zombie streaming self-heal on scenePhase

    func test_handleScenePhaseActive_zombieStreaming_reattaches() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .writing)
        // First phase: every reattach drops → exhausts 3 attempts → the final
        // GET-reconcile sees status==.writing → leaves a "zombie" .streaming with
        // NO active task (the exact state the fix must recover from).
        mock.onReattachThrowAfterEvents = (events: [], error: AppError.transport("down"))

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)  // auto-reattach on writing → exhausts → zombie
        // Wait out the reattach loop (3 attempts × 0.4s backoff) + refresh.
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let callsBefore = mock.calls.filter { $0 == "reattachWriteStream" }.count
        XCTAssertEqual(callsBefore, 3, "initial auto-reattach should have exhausted 3 attempts into a zombie")

        // Network recovers: the next reattach completes.
        mock.onReattachThrowAfterEvents = nil
        var doneChapter = chapter
        doneChapter.status = .draftReady
        doneChapter.draftText = "唤醒后重连拿到的稿。"
        mock.onReattach = { id in [.started(chapterId: id), .done(chapter: doneChapter)] }

        // scenePhase active: status==.writing + no active task → must reattach,
        // even though writingState is (zombie) .streaming.
        store.handleScenePhaseActive()
        await waitUntilSettled(store)
        let callsAfter = mock.calls.filter { $0 == "reattachWriteStream" }.count
        XCTAssertGreaterThan(callsAfter, callsBefore, "scenePhase active must reattach a zombie-streaming writing chapter")
        XCTAssertEqual(store.writingState, .done)
    }

    // MARK: 审后修复 #4 — terminal error is definitive, not a transient retry

    func test_reattach_terminalError_publishesRealErrorAndDoesNotRetry() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        let realError = AppError.upstream("LLM 服务调用失败：具体原因", retryable: true)
        mock.onReattach = { id in [.started(chapterId: id), .error(realError)] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.reattachWriting()
        await waitUntilSettled(store)

        if case .failed(let e) = store.writingState {
            XCTAssertEqual(e, realError, "must surface the real upstream error, not a generic 连接中断")
        } else {
            XCTFail("terminal error must land .failed, got \(store.writingState)")
        }
        XCTAssertEqual(bus.current?.message, realError.message)
        // Definitive failure → exactly ONE reattach attempt, no 3× retry burn.
        XCTAssertEqual(mock.calls.filter { $0 == "reattachWriteStream" }.count, 1,
                       "a terminal error must not be retried as a transient disconnect")
    }
}
