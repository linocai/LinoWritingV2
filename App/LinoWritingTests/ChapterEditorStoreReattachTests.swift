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
            switch store.writingState {
            case .streaming, .revising:
                try? await Task.sleep(nanoseconds: 5_000_000)
            default:
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
                .done(chapter: doneChapter, revision: nil),
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
            [.started(chapterId: id), .snapshot(buffer: "", chars: 0), .done(chapter: doneChapter, revision: nil)]
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
        mock.onReattach = { id in [.started(chapterId: id), .done(chapter: doneChapter, revision: nil)] }

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
        mock.onReattach = { id in [.started(chapterId: id), .done(chapter: doneChapter, revision: nil)] }

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

    // MARK: v1.4.0 (MM) P4 — two-pass revising phase + standalone revise()

    func test_revise_callsReviseStreamEndpoint() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .draftReady)

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)

        store.revise()
        await waitUntilSettled(store)

        XCTAssertTrue(mock.calls.contains("reviseStream"), "revise() must call POST /chapters/{id}/revise")
        XCTAssertEqual(store.writingState, .done)
    }

    func test_revise_inRange_setsLastRevisionOutcome_noToast() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .draftReady)
        var doneChapter = chapter
        doneChapter.draftText = "已在区间内的稿，无需压缩。"
        mock.onRevise = { id in [.started(chapterId: id), .revising, .done(chapter: doneChapter, revision: "in_range")] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.revise()
        await waitUntilSettled(store)

        XCTAssertEqual(store.lastRevisionOutcome, "in_range")
        XCTAssertNil(bus.current, "in_range must not publish a Toast")
    }

    func test_revise_unrevised_setsLastRevisionOutcome_andPublishesToast() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .draftReady)
        var doneChapter = chapter
        doneChapter.draftText = "压缩失败，保留的初稿。"
        mock.onRevise = { id in [.started(chapterId: id), .revising, .done(chapter: doneChapter, revision: "unrevised")] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.revise()
        await waitUntilSettled(store)

        XCTAssertEqual(store.lastRevisionOutcome, "unrevised")
        XCTAssertEqual(bus.current?.message, "字数超标但自动修订失败，已保留初稿，可手动重试修订")
        XCTAssertEqual(store.chapter?.draftText, "压缩失败，保留的初稿。", "the draft must be kept, never lost")
    }

    func test_write_crossingIntoRevising_carriesStreamingBufferForward() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock)
        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "超长初稿压缩后的正文。"
            c.status = .draftReady
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) { mock.chapters[idx] = c }
            return [
                .started(chapterId: chapterId),
                .token(text: "超长初稿"),
                .progress(chars: 4),
                .revising,
                .done(chapter: c, revision: "revised"),
            ]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.startWriting()
        await waitUntilSettled(store)

        XCTAssertEqual(store.writingState, .done)
        XCTAssertEqual(store.lastRevisionOutcome, "revised")
        XCTAssertEqual(store.chapter?.draftText, "超长初稿压缩后的正文。")
    }

    /// A live reattach that lands mid-revising must replay `snapshot` then
    /// `revising`, transitioning `.streaming` → `.revising` and carrying the
    /// snapshot buffer/chars forward (🔵9) — never dropping the draft.
    func test_reattach_partialThenRevising_carriesSnapshotBufferIntoRevisingState() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .writing)
        // Every reattach attempt replays snapshot+revising, then drops
        // (transient) — the .revising(buffer:chars:) state persists across
        // the retry backoff since nothing resets it on a mere disconnect.
        mock.onReattachThrowAfterEvents = (
            events: [.started(chapterId: chapter.id), .snapshot(buffer: "已完成的初稿全文", chars: 8), .revising],
            error: AppError.transport("down")
        )

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)  // status == .writing → auto reattach

        await waitUntil { store.isRevising }
        if case .revising(let buffer, let chars) = store.writingState {
            XCTAssertEqual(buffer, "已完成的初稿全文")
            XCTAssertEqual(chars, 8)
        } else {
            XCTFail("expected .revising carrying the snapshot buffer forward, got \(store.writingState)")
        }
    }

    /// `lastRevisionOutcome` is ephemeral: it must not survive a chapter
    /// switch/reload (plan §4 P4 — never persisted).
    func test_lastRevisionOutcome_clearsOnChapterReload() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .draftReady)
        var doneChapter = chapter
        doneChapter.draftText = "压缩失败，保留的初稿。"
        mock.onRevise = { id in [.started(chapterId: id), .revising, .done(chapter: doneChapter, revision: "unrevised")] }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.revise()
        await waitUntilSettled(store)
        XCTAssertEqual(store.lastRevisionOutcome, "unrevised")

        await store.load(chapterId: chapter.id)  // reload the same chapter
        XCTAssertNil(store.lastRevisionOutcome, "ephemeral marker must vanish on reload")
    }

    /// 审后修复 🟡5 — `startWriting` must clear `lastRevisionOutcome` at
    /// kickoff too, same as `revise()` already does (the doc comment on the
    /// property claimed both did; `startWriting` didn't). Without this, a
    /// stale "unrevised" from a PRIOR completed revise on this chapter keeps
    /// showing the "未修订" tag all the way through a brand new
    /// regeneration, pointing at content that no longer exists.
    func test_startWriting_clearsStaleLastRevisionOutcomeFromPriorRevise() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let chapter = await makeReadyChapter(mock, status: .draftReady)
        var revisedDoneChapter = chapter
        revisedDoneChapter.draftText = "压缩失败，保留的初稿。"
        mock.onRevise = { id in
            [.started(chapterId: id), .revising, .done(chapter: revisedDoneChapter, revision: "unrevised")]
        }

        let store = ChapterEditorStore(api: mock, errorBus: bus)
        await store.load(chapterId: chapter.id)
        store.revise()
        await waitUntilSettled(store)
        XCTAssertEqual(store.lastRevisionOutcome, "unrevised", "precondition: a completed revise left the stale marker")

        // Start a brand new regeneration on the SAME chapter (no reload in
        // between) — the stale "未修订" marker must not linger through it.
        mock.onWrite = { chapterId in
            var c = mock.chapters.first { $0.id == chapterId }!
            c.draftText = "全新一稿。"
            c.status = .draftReady
            if let idx = mock.chapters.firstIndex(where: { $0.id == chapterId }) { mock.chapters[idx] = c }
            return [.started(chapterId: chapterId), .token(text: "全新一稿。"), .done(chapter: c, revision: nil)]
        }
        store.startWriting()
        XCTAssertNil(store.lastRevisionOutcome, "startWriting must clear the stale marker synchronously at kickoff")
        await waitUntilSettled(store)
        XCTAssertNil(store.lastRevisionOutcome, "must stay cleared through completion (this done carries no revision)")
    }
}
