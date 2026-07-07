import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Live state of the currently-open chapter, including the streaming buffer.
@MainActor
public final class ChapterEditorStore: ObservableObject {

    public enum WritingState: Equatable {
        case idle
        case streaming(buffer: String, chars: Int)
        case done
        case failed(AppError)
    }

    @Published public private(set) var chapter: Chapter?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var writingState: WritingState = .idle {
        didSet {
            #if os(iOS)
            // v1.3.1 (KK) P5 — iOS screen-sleep-during-streaming fix
            // (治标). Structural, state-source-driven rather than
            // point-naming every exit (`.done`/`.failed`/`stopWriting`
            // each separately, which is easy to miss — see plan-critic
            // 🔵#6): every `writingState` mutation runs through this one
            // `didSet`, and `updateStreamingSideEffects` edge-detects the
            // streaming↔non-streaming boundary so the idle-timer/
            // background-task toggle fires exactly once per transition,
            // not on every token/progress buffer append while streaming.
            updateStreamingSideEffects(oldValue: oldValue, newValue: writingState)
            #endif
        }
    }
    /// v1.2.0 (HH) P7 — accumulated chain-of-thought text from `.thinking`
    /// SSE frames, kept separate from `writingState`'s draft buffer so the
    /// "模型思考中…" UI indicator never mixes with (or gets mistaken for)
    /// final prose. Reset to empty whenever a new write starts or the
    /// editor tears down (`resetAllPublishedToIdle`). Not persisted, not
    /// counted toward word count — purely a transient process indicator.
    @Published public private(set) var thinkingBuffer: String = ""
    /// True while `.thinking` frames are actively arriving and no `.token`
    /// has superseded them yet this stream — drives the "模型思考中…"
    /// indicator's visibility. Cleared the moment the first `.token` for
    /// this write arrives (thinking is done once real prose starts).
    public var isThinking: Bool {
        isStreaming && !thinkingBuffer.isEmpty && streamingBufferIsEmpty
    }
    /// Backing check for `isThinking` — true once any token text has
    /// arrived this stream, so "thinking" never lingers visually once the
    /// model has moved on to writing prose.
    private var streamingBufferIsEmpty: Bool {
        if case .streaming(let buffer, _) = writingState { return buffer.isEmpty }
        return true
    }

    /// True while an SSE write stream is in flight — used by the toolbar
    /// to short-circuit the chapter.status switch so users can't fire a
    /// second POST /write before the first one has flipped the backend
    /// status to "writing". Otherwise rapid double-clicks during the
    /// 200ms gap before the first token arrives produce 409 Conflicts.
    public var isStreaming: Bool {
        if case .streaming = writingState { return true }
        return false
    }
    @Published public private(set) var isExpanding: Bool = false
    @Published public private(set) var isFinalizing: Bool = false
    @Published public private(set) var isImporting: Bool = false
    /// In-flight flag for the v0.9.3 §5.DI.3 manual "提取角色/时间线" path.
    /// Toolbar uses it to disable the button + show a spinner while the
    /// Extractor round-trip is running so the user can't fire a second
    /// extract before the first returns.
    @Published public private(set) var isExtracting: Bool = false
    /// In-flight flag for the §5.P.1 E "强制重置" path. Toolbar uses
    /// it to disable the menu item while the network round-trip is in
    /// flight so the user can't double-click and fire two redundant
    /// admin_reset requests (the backend would happily idempotent them
    /// per P-1+P-3 reviewer 🟡 #5, but the UI should still give clear
    /// "in progress" feedback). P-2 reviewer 🟡 #2.
    @Published public private(set) var isAdminResetting: Bool = false

    /// IDs the latest finalize OR import call modified — exposed for the
    /// right panel highlight. Both code paths write here because the
    /// downstream dot-indicator UX is identical: "Agent touched these cards".
    @Published public private(set) var lastUpdatedCharacterIds: [String] = []

    private let api: APIClientProtocol
    private let errorBus: ErrorBus
    private var streamTask: Task<Void, Never>?
    /// v1.3.2 (LL) P2 审后修复 #3: true while a `startWriting`/`reattachWriting`
    /// stream task is actively running. Distinct from `writingState == .streaming`
    /// because `refreshAfterIncompleteStream` can leave a "zombie" `.streaming`
    /// after its task has ended — and a completed `Task` stays referenced, so
    /// `streamTask != nil` can't tell active from finished. scenePhase recovery
    /// keys off THIS so a zombie streaming self-heals (re-enabling the iOS idle
    /// timer that would otherwise stay disabled forever).
    private var streamTaskActive = false

    #if os(iOS)
    /// v1.3.1 (KK) P5 — the UIKit background task token for the current
    /// streaming write, if any. `.invalid` sentinel semantics are handled by
    /// only ever calling `endBackgroundTask` when this is non-nil.
    private var backgroundTaskId: UIBackgroundTaskIdentifier?
    #endif

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    #if os(iOS)
    // MARK: - iOS screen-sleep-during-streaming fix (v1.3.1 KK P5, 治标)

    /// Edge-detects the streaming↔non-streaming boundary on every
    /// `writingState` mutation (driven by the `didSet` above) and toggles
    /// `UIApplication.isIdleTimerDisabled` + a UIKit background task exactly
    /// once per transition — never per-token. This is the single source of
    /// truth the plan calls for (plan-critic 🔵#6), replacing the
    /// easy-to-miss alternative of point-naming `.done`/`.failed`/
    /// `stopWriting` separately.
    private func updateStreamingSideEffects(oldValue: WritingState, newValue: WritingState) {
        let wasStreaming: Bool = { if case .streaming = oldValue { return true }; return false }()
        let isStreamingNow: Bool = { if case .streaming = newValue { return true }; return false }()
        guard wasStreaming != isStreamingNow else { return }
        if isStreamingNow {
            beginStreamingProtection()
        } else {
            endStreamingProtection()
        }
    }

    /// Disables the idle timer (screen won't auto-sleep while the app is in
    /// the foreground) and opens a UIKit background task so the SSE stream
    /// gets roughly ~30s of grace to keep running after the user backgrounds
    /// the app or the screen locks, instead of being suspended immediately.
    /// This is 治标, not 治本 — see PROJECT_PLAN §4 P5 / Backlog "写作作业化".
    private func beginStreamingProtection() {
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        print("[P5] idle timer disabled (writing started)")
        #endif
        // Repeated `startWriting` before the previous stream's background
        // task ended would otherwise leak a task token — end any stale one
        // first (defensive; `updateStreamingSideEffects` normally already
        // closed it via the non-streaming transition before a new stream
        // can start, since `startWriting` always drives writingState through
        // `.streaming` fresh, but this guards against any future call path
        // that skips that).
        endBackgroundTaskIfAny()

        // v1.3.1 (KK) 审后修复 建议#4: Apple's documented contract for
        // `beginBackgroundTask(expirationHandler:)` is "call
        // `endBackgroundTask` **synchronously, within the handler**" — the
        // previous version hopped through `Task { @MainActor in
        // self.endBackgroundTaskIfAny() }`, deferring the actual end call to
        // a later run-loop turn. That's both a deviation from the documented
        // pattern and a narrow race: if a *new* stream starts in the window
        // between the handler firing and the deferred Task actually running,
        // `self.backgroundTaskId` would already hold the *new* task's id by
        // the time the stale closure's `endBackgroundTaskIfAny()` runs,
        // which would end the wrong (new) task.
        //
        // Fixed per the standard pattern: capture this specific `id` in a
        // local `var` (assigned right after `beginBackgroundTask` returns)
        // and call `endBackgroundTask(id)` directly inside the handler —
        // `endBackgroundTask` itself is safe to call from any thread/queue
        // per Apple's API contract, no actor hop needed. `self.backgroundTaskId`
        // is only cleared here if it still matches (guards against clearing
        // a newer id that superseded this one through the normal
        // `endStreamingProtection` path already running first).
        var capturedId: UIBackgroundTaskIdentifier = .invalid
        capturedId = UIApplication.shared.beginBackgroundTask(withName: "LinoWriting.chapterWrite") { [weak self] in
            UIApplication.shared.endBackgroundTask(capturedId)
            #if DEBUG
            print("[P5] background task expiration handler fired — ended id=\(capturedId) synchronously")
            #endif
            Task { @MainActor in
                guard let self, self.backgroundTaskId == capturedId else { return }
                self.backgroundTaskId = nil
            }
        }
        backgroundTaskId = capturedId
        #if DEBUG
        print("[P5] background task begun, id=\(capturedId)")
        #endif
    }

    private func endStreamingProtection() {
        UIApplication.shared.isIdleTimerDisabled = false
        #if DEBUG
        print("[P5] idle timer re-enabled (writing ended)")
        #endif
        endBackgroundTaskIfAny()
    }

    private func endBackgroundTaskIfAny() {
        guard let id = backgroundTaskId, id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        backgroundTaskId = nil
        #if DEBUG
        print("[P5] background task ended, id=\(id)")
        #endif
    }
    #endif

    // MARK: Loading

    public func load(chapterId: String) async {
        // PROJECT_PLAN v0.7 §5.P.1 G: switching chapters must give a clean
        // slate. Before this guard, `lastUpdatedCharacterIds` from a prior
        // finalize/import would bleed into the new chapter's right-panel
        // highlight (reviewer caught the red-dot leaking to chapter B after
        // finalizing chapter A). Same risk for `isImporting`/`isExpanding`
        // /`isFinalizing` if the user navigates away mid-action — the new
        // chapter would render with a stale spinner. Reset everything to
        // an idle baseline up front; if `api.getChapter` fails below we
        // still want the wiped state so the empty view shows correctly.
        resetAllPublishedToIdle()
        isLoading = true
        defer { isLoading = false }
        do {
            let chapter = try await api.getChapter(id: chapterId)
            self.chapter = chapter
            // v1.3.2 (LL) P2 — a chapter loaded in `writing` status has (or had)
            // a backend write job running independently of any client. Auto-
            // reattach to resume the live token view / reconcile the outcome
            // (or surface 强制重置 if the worker was lost to a restart).
            if chapter.status == .writing {
                reattachWriting()
            }
        } catch let error as AppError {
            errorBus.publish(error)
            self.chapter = nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func reset() {
        resetAllPublishedToIdle()
    }

    /// Single source of truth for "wipe every per-chapter @Published back
    /// to an idle baseline". Called from both `load(chapterId:)` (so
    /// switching chapters never leaks state) and `reset()` (book/workspace
    /// teardown), plus the `adminReset` escape hatch which needs the same
    /// clean slate after force-rewriting the backend chapter status.
    ///
    /// `isLoading` is intentionally **not** touched here — it's owned by
    /// the calling async function via its own `defer` and represents
    /// "network in flight", not per-chapter state.
    private func resetAllPublishedToIdle() {
        // v1.3.2 (LL) P2 — tear down only the LOCAL stream task; the backend
        // write job (if any) keeps running. Switching chapters / tearing down
        // the workspace must NOT cancel an in-flight write (the whole point of
        // writing-as-a-job). `writingState` is set to `.idle` explicitly below.
        detach()
        chapter = nil
        writingState = .idle
        thinkingBuffer = ""
        isExpanding = false
        isFinalizing = false
        isImporting = false
        isExtracting = false
        lastUpdatedCharacterIds = []
    }

    // MARK: Inline edits

    public func patchUserPrompt(_ value: String) async {
        await patch(ChapterPatchRequest(userPrompt: value))
    }

    public func patchTitle(_ value: String) async {
        await patch(ChapterPatchRequest(title: value))
    }

    public func patchStructuredPrompt(_ value: StructuredPrompt) async {
        await patch(ChapterPatchRequest(structuredPrompt: value))
    }

    public func patchDraftText(_ value: String) async {
        await patch(ChapterPatchRequest(draftText: value))
    }

    private func patch(_ payload: ChapterPatchRequest) async {
        guard let chapter else { return }
        do {
            let updated = try await api.patchChapter(id: chapter.id, payload)
            self.chapter = updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    // MARK: Flow actions

    /// Returns the updated chapter on success so the chapters list store can refresh.
    public func expand(force: Bool = false) async -> Chapter? {
        guard let chapter else { return nil }
        isExpanding = true
        defer { isExpanding = false }
        do {
            let updated = try await api.expand(chapterId: chapter.id, force: force)
            self.chapter = updated
            return updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// v1.3.2 (LL) P2 — outcome of consuming one write/reattach SSE stream.
    private enum StreamStep { case cont, settled }
    private enum ReattachOutcome { case settled, transientFailure }

    /// Apply a single SSE event to the published state. Shared by
    /// `startWriting` and `reattachWriting`. Returns `.settled` once the stream
    /// has reached a terminal state (done / error / stranded / no-active).
    private func applyWriteEvent(_ event: SSEEvent, onDone: (@MainActor (Chapter) -> Void)?) -> StreamStep {
        switch event {
        case .started:
            return .cont
        case .snapshot(let buffer, let chars):
            // Reattach only: rebuild the buffer from the backend's replay before
            // tailing. Never carries thinking text.
            writingState = .streaming(buffer: buffer, chars: chars)
            return .cont
        case .token(let text):
            if case .streaming(var buf, let chars) = writingState {
                buf += text
                writingState = .streaming(buffer: buf, chars: chars + text.count)
            } else {
                writingState = .streaming(buffer: text, chars: text.count)
            }
            return .cont
        case .thinking(let text):
            // v1.2.0 (HH) P7: accumulate into the separate thinkingBuffer —
            // never touches writingState's draft buffer/chars.
            thinkingBuffer += text
            return .cont
        case .progress(let chars):
            if case .streaming(let buf, _) = writingState {
                writingState = .streaming(buffer: buf, chars: chars)
            }
            return .cont
        case .done(let chapter):
            self.chapter = chapter
            writingState = .done
            onDone?(chapter)
            return .settled
        case .error(let appError):
            writingState = .failed(appError)
            errorBus.publish(appError)
            return .settled
        case .reattachStranded:
            // The DB row is stuck in `writing` but the worker was lost (server
            // restart). Point the user at the 强制重置 escape hatch.
            let e = AppError.conflict("写作进程已丢失（可能因服务重启），请对本章「强制重置」后重试")
            writingState = .failed(e)
            errorBus.publish(e)
            return .settled
        case .reattachNoActive:
            // Nothing is being written — silently drop to idle, NO Toast.
            if case .streaming = writingState { writingState = .idle }
            return .settled
        case .other:
            return .cont
        }
    }

    /// Kick off SSE writing. Caller stays alive via the task held in `streamTask`.
    public func startWriting(onDone: (@MainActor (Chapter) -> Void)? = nil) {
        guard let chapter else { return }
        detach()
        writingState = .streaming(buffer: "", chars: 0)
        thinkingBuffer = ""

        streamTaskActive = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            defer { self.streamTaskActive = false }
            do {
                for try await event in self.api.writeStream(chapterId: chapter.id) {
                    if Task.isCancelled { return }
                    if case .settled = self.applyWriteEvent(event, onDone: onDone) { return }
                }
                // Stream ended without an explicit terminal — treat as a drop.
                if case .streaming = self.writingState {
                    await self.handleStreamDrop(
                        originalError: .upstream("写作中断，可点重新生成", retryable: true),
                        onDone: onDone
                    )
                }
            } catch let error as AppError {
                // v1.3.2 (LL) P2 (🔴1): a real disconnect (URLSession timeout /
                // dropped connection) throws here. The backend job is (very
                // likely) STILL running — do not declare failure. Reattach first
                // (bounded), then reconcile. A user-initiated cancel is the one
                // exception (handled by `stopWriting`; `.cancelled` short-circuits).
                let wasStreaming: Bool = { if case .streaming = self.writingState { return true }; return false }()
                if wasStreaming, error != .cancelled {
                    await self.handleStreamDrop(originalError: error, onDone: onDone)
                } else {
                    self.writingState = .failed(error)
                    if error != .cancelled { self.errorBus.publish(error) }
                }
            } catch {
                let wasStreaming: Bool = { if case .streaming = self.writingState { return true }; return false }()
                let mapped = AppError.transport(error.localizedDescription)
                if wasStreaming {
                    await self.handleStreamDrop(originalError: mapped, onDone: onDone)
                } else {
                    self.writingState = .failed(mapped)
                    self.errorBus.publish(mapped)
                }
            }
        }
    }

    /// v1.3.2 (LL) P2 (🔴1) — a start stream ended/threw mid-write without a
    /// terminal frame. Because the backend job keeps running independently of
    /// the connection, do NOT declare failure: first reattach (bounded retries),
    /// and only if every attempt fails do a final GET-and-reconcile.
    private func handleStreamDrop(
        originalError: AppError,
        onDone: (@MainActor (Chapter) -> Void)?
    ) async {
        let outcome = await reattachLoop(maxAttempts: 3, onDone: onDone)
        if case .transientFailure = outcome {
            await refreshAfterIncompleteStream(originalError: originalError, onDone: onDone)
        }
    }

    /// v1.3.2 (LL) P2 — reattach to a backend write that outlived our local
    /// stream (chapter switch, phone sleep, transient disconnect). Runs the
    /// bounded reattach→reconcile machine on its own `streamTask`.
    public func reattachWriting(onDone: (@MainActor (Chapter) -> Void)? = nil) {
        guard chapter != nil else { return }
        detach()
        // Show streaming while reattaching (also re-arms the iOS idle-timer
        // guard via `writingState.didSet`).
        writingState = .streaming(buffer: "", chars: 0)
        thinkingBuffer = ""
        streamTaskActive = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            defer { self.streamTaskActive = false }
            let outcome = await self.reattachLoop(maxAttempts: 3, onDone: onDone)
            if case .transientFailure = outcome {
                await self.refreshAfterIncompleteStream(
                    originalError: .upstream("写作连接中断，可点重新生成", retryable: true),
                    onDone: onDone
                )
            }
        }
    }

    /// Reattach with bounded retries. `.settled` = reached a definite state
    /// (done / error / stranded / no-active / user-cancel); `.transientFailure`
    /// = every attempt's stream dropped before a terminal (network still bad).
    private func reattachLoop(
        maxAttempts: Int,
        onDone: (@MainActor (Chapter) -> Void)?
    ) async -> ReattachOutcome {
        guard chapter != nil else { return .settled }
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return .settled }
            if case .settled = await consumeReattachOnce(onDone: onDone) { return .settled }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: 400_000_000)  // 0.4s backoff
            }
        }
        return .transientFailure
    }

    private func consumeReattachOnce(onDone: (@MainActor (Chapter) -> Void)?) async -> ReattachOutcome {
        guard let chapter else { return .settled }
        do {
            for try await event in api.reattachWriteStream(chapterId: chapter.id) {
                if Task.isCancelled { return .settled }
                if case .settled = applyWriteEvent(event, onDone: onDone) { return .settled }
            }
            // Stream ended without a terminal (dropped mid-tail) → transient.
            return .transientFailure
        } catch let error as AppError {
            return error == .cancelled ? .settled : .transientFailure
        } catch {
            return .transientFailure
        }
    }

    /// v1.3.2 (LL) P2 — the app returned to the foreground. If the chapter is
    /// mid-write server-side but no stream task is actively watching, reattach to
    /// resume the live view (this is the "手机息屏 5 分钟回来" recovery path).
    ///
    /// 审后修复 #3: the judge is `streamTaskActive`, NOT `if case .streaming`. A
    /// `refreshAfterIncompleteStream` that ended on a still-`writing` backend
    /// leaves a "zombie" `.streaming` with no live task; keying off the flag
    /// self-heals it here (and re-enables the iOS idle timer, since the fresh
    /// reattach task eventually settles to a non-streaming state).
    public func handleScenePhaseActive() {
        guard let chapter, chapter.status == .writing else { return }
        if streamTaskActive { return }  // a task is already watching
        reattachWriting()
    }

    /// GET-and-reconcile after every reattach attempt failed.
    ///
    /// v1.3.2 (LL) P2 (🔴1): reached only after reattach retries are exhausted.
    /// Contract: GET succeeds AND `status == .draftReady` AND non-empty draft →
    /// `.done`. If the GET shows `status == .writing`, the backend is genuinely
    /// still writing — this is NOT a failure: leave the (streaming) state
    /// untouched, publish nothing, and let the next load/scenePhase reattach
    /// recover the live view. Otherwise → `.failed(originalError)` + publish.
    private func refreshAfterIncompleteStream(
        originalError: AppError,
        onDone: (@MainActor (Chapter) -> Void)?
    ) async {
        guard let chapter else {
            writingState = .failed(originalError)
            errorBus.publish(originalError)
            return
        }
        do {
            let refreshed = try await api.getChapter(id: chapter.id)
            self.chapter = refreshed
            if refreshed.status == .draftReady, let draft = refreshed.draftText, !draft.isEmpty {
                self.writingState = .done
                onDone?(refreshed)
            } else if refreshed.status == .writing {
                // Backend is still writing — do NOT declare failure. Keep the
                // streaming state we already have; recovery comes from the next
                // load()/scenePhase reattach. No Toast.
                if case .streaming = self.writingState {
                    // leave as-is (preserve any partial buffer + the stop button)
                } else {
                    self.writingState = .streaming(buffer: "", chars: 0)
                }
            } else {
                self.writingState = .failed(originalError)
                self.errorBus.publish(originalError)
            }
        } catch {
            self.writingState = .failed(originalError)
            self.errorBus.publish(originalError)
        }
    }

    /// v1.3.2 (LL) P2 — tear down only the LOCAL SSE stream task. The backend
    /// write job (if any) keeps running: leaving/switching chapters or the app
    /// backgrounding must NOT cancel a write. Callers set `writingState`
    /// themselves (this does not touch it, unlike the old `cancelStream`).
    public func detach() {
        streamTask?.cancel()
        streamTask = nil
        streamTaskActive = false
    }

    /// v1.3.2 (LL) P2 — explicit "停止生成": the ONLY path that actually stops a
    /// backend write. Cancels via `POST /write/cancel`, detaches the local
    /// stream, and reconciles the returned row (still `writing` if the worker
    /// didn't wind down inside the server's bounded wait → keep reattaching).
    ///
    /// 审后修复 #2: this cancel round-trip runs on an orphan `Task` NOT held in
    /// `streamTask` (so a later `reattachWriting`'s `detach` doesn't self-cancel
    /// it). That means a chapter switch can't cancel it either — so before
    /// applying ANY result we re-check the still-open chapter matches the one we
    /// cancelled, and discard otherwise. Without this guard a late cancel
    /// response could overwrite the newly-opened chapter or (still-writing path)
    /// detach the new chapter's live stream and pour the old chapter's tokens
    /// onto the current screen.
    public func stopWriting() {
        guard let chapter else { detach(); writingState = .idle; return }
        let chapterId = chapter.id
        detach()  // stop consuming locally; the buffer stays visible until we hear back
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.api.cancelWrite(chapterId: chapterId)
                guard self.chapter?.id == chapterId else { return }  // switched away → discard
                self.chapter = updated
                if updated.status == .writing {
                    // Worker didn't finish inside the server's wait window —
                    // keep reconciling by reattaching to catch the terminal.
                    self.reattachWriting()
                } else {
                    // draft_ready (partial salvaged) / prompt_ready (nothing to
                    // save) / etc. — settled.
                    self.writingState = .idle
                }
            } catch let error as AppError {
                guard self.chapter?.id == chapterId else { return }
                if error != .cancelled { self.errorBus.publish(error) }
                self.writingState = .idle
            } catch {
                guard self.chapter?.id == chapterId else { return }
                self.errorBus.publish(.transport(error.localizedDescription))
                self.writingState = .idle
            }
        }
    }

    /// Returns (chapter, updatedCharacterIds) on success.
    public func finalize() async -> FinalizeResult? {
        guard let chapter else { return nil }
        isFinalizing = true
        defer { isFinalizing = false }
        do {
            let result = try await api.finalize(chapterId: chapter.id)
            self.chapter = result.chapter
            self.lastUpdatedCharacterIds = result.updatedCharacterIds
            return result
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// Manually re-runs the Extractor against the current (`finalized`)
    /// chapter via `POST /chapters/{id}/extract` (PROJECT_PLAN v0.9.3
    /// §5.DI.3). Mirrors `finalize()`: flips `isExtracting`, writes the
    /// returned chapter + `lastUpdatedCharacterIds` (so the right-panel
    /// highlight reuses the same pipe finalize/import already drive), and
    /// returns the full envelope so the toolbar can refresh dependent
    /// stores. Returns `nil` on failure; the error is already published to
    /// `ErrorBus` and the chapter row is left untouched (the backend
    /// doesn't mutate draft_text / status on extract).
    public func extract() async -> ChapterImportResponse? {
        guard let chapter else { return nil }
        isExtracting = true
        defer { isExtracting = false }
        do {
            let result = try await api.extractChapter(id: chapter.id)
            self.chapter = result.chapter
            self.lastUpdatedCharacterIds = result.updatedCharacterIds
            return result
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    public func reopen() async -> Chapter? {
        guard let chapter else { return nil }
        do {
            let updated = try await api.reopen(chapterId: chapter.id)
            self.chapter = updated
            return updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// Imports user-authored chapter text via `POST /chapters/{id}/import`
    /// (PROJECT_PLAN §5.A.4 / §5.A.6).
    ///
    /// On success the chapter ends in `finalized` status with
    /// `source == .imported`. When `run_extractor=true` (the sheet's default)
    /// the response also carries any character/timeline IDs the Extractor
    /// touched — mirrors `finalize()`'s payload, so callers can fan out the
    /// dependent-store refreshes identically (see `ChapterToolbar`).
    ///
    /// Returns the full response so callers can highlight `updated_character_ids`
    /// and refresh stores. Returns `nil` on failure; the error is already
    /// published to `ErrorBus`.
    /// Force-reset a stuck chapter to an editable state via
    /// `POST /chapters/{id}/admin_reset` (PROJECT_PLAN v0.7 §5.P.1 E).
    ///
    /// The backend accepts any current status (including `writing` and
    /// `finalized`) and rewrites it to `targetStatus` while preserving
    /// `draft_text` / `structured_prompt`. Used as the "我卡死了" escape
    /// hatch when a chapter is stranded after an SSE crash, client kill,
    /// or server restart mid-stream.
    ///
    /// After success the entire @Published surface is wiped — `isStreaming`,
    /// `lastUpdatedCharacterIds`, etc. are all stale once the underlying
    /// chapter has been forcibly rewritten under us. The fresh chapter
    /// is reinstalled afterwards so the editor view re-renders cleanly.
    ///
    /// Returns `true` on success. Errors are published to `ErrorBus`.
    @discardableResult
    public func adminReset(targetStatus: ChapterStatus = .draftReady) async -> Bool {
        guard let chapter else { return false }
        let chapterId = chapter.id
        isAdminResetting = true
        defer { isAdminResetting = false }
        do {
            let refreshed = try await api.adminResetChapter(
                id: chapterId,
                targetStatus: targetStatus
            )
            // Wipe every per-chapter flag first — the user just triggered a
            // forced state change, so any in-flight `isImporting` /
            // `isFinalizing` / streaming buffer is meaningless. Then
            // reinstall the fresh chapter so the editor view re-renders.
            resetAllPublishedToIdle()
            self.chapter = refreshed
            return true
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return false
    }

    public func importChapter(_ payload: ChapterImportRequest) async -> ChapterImportResponse? {
        guard let chapter else { return nil }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await api.importChapter(id: chapter.id, payload: payload)
            self.chapter = result.chapter
            // Mirror finalize's side-effect: the right panel highlights any
            // characters whose live_fields the Extractor changed.
            self.lastUpdatedCharacterIds = result.updatedCharacterIds
            return result
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }
}
