import Foundation
import SwiftUI

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
    @Published public private(set) var writingState: WritingState = .idle
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

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

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
        // Tear down any in-flight SSE stream first so its task doesn't
        // race to flip `writingState` back to .streaming after we clear it.
        cancelStream()
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

    /// Kick off SSE writing. Caller stays alive via the task held in `streamTask`.
    public func startWriting(onDone: (@MainActor (Chapter) -> Void)? = nil) {
        guard let chapter else { return }
        cancelStream()
        writingState = .streaming(buffer: "", chars: 0)
        thinkingBuffer = ""

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.api.writeStream(chapterId: chapter.id) {
                    if Task.isCancelled { return }
                    switch event {
                    case .started:
                        continue
                    case .token(let text):
                        if case .streaming(var buf, let chars) = self.writingState {
                            buf += text
                            self.writingState = .streaming(buffer: buf, chars: chars + text.count)
                        } else {
                            self.writingState = .streaming(buffer: text, chars: text.count)
                        }
                    case .thinking(let text):
                        // v1.2.0 (HH) P7: accumulate into the separate
                        // thinkingBuffer — never touches writingState's
                        // draft buffer/chars, so reasoning text can't leak
                        // into the saved chapter or the word count.
                        self.thinkingBuffer += text
                    case .progress(let chars):
                        if case .streaming(let buf, _) = self.writingState {
                            self.writingState = .streaming(buffer: buf, chars: chars)
                        }
                    case .done(let chapter):
                        self.chapter = chapter
                        self.writingState = .done
                        onDone?(chapter)
                        return
                    case .error(let appError):
                        self.writingState = .failed(appError)
                        self.errorBus.publish(appError)
                        return
                    case .other:
                        continue
                    }
                }
                // Stream ended without an explicit done — if we have a chapter, refresh it.
                if case .streaming = self.writingState {
                    await self.refreshAfterIncompleteStream(
                        originalError: .upstream("写作中断，可点重新生成", retryable: true),
                        onDone: onDone
                    )
                }
            } catch let error as AppError {
                // v0.8 Phase U-2 (§5.U.5): SSE 弱网断流不自动重连(会丢已收 token);
                // 落到 .failed 状态由 toolbar 让用户主动决定重新生成 / 取消。
                //
                // v1.2.0 (HH) P5 (致命 1, plan-critic 拦下): a real disconnect
                // (URLSession timeout / dropped connection) throws here rather
                // than ending the loop gracefully, so `refreshAfterIncompleteStream`
                // (wired to the graceful "stream ended without done" path above)
                // never used to run for this case — the backend's P5 partial-draft
                // save (previous_status == prompt_ready → draft_ready) went
                // undiscovered until the author manually reopened the chapter.
                // If we were mid-stream and the failure isn't a user-initiated
                // cancel, do the same GET-and-reconcile the graceful path does
                // before giving up: the backend may have salvaged a partial
                // draft, and `refreshAfterIncompleteStream` already knows how to
                // promote that to `.done` (or fall back to `.failed` if the GET
                // itself fails or the chapter still shows no usable draft).
                let wasStreaming: Bool = { if case .streaming = self.writingState { return true }; return false }()
                if wasStreaming, error != .cancelled {
                    await self.refreshAfterIncompleteStream(originalError: error, onDone: onDone)
                } else {
                    self.writingState = .failed(error)
                    if error != .cancelled { self.errorBus.publish(error) }
                }
            } catch {
                // v0.8 Phase U-2 (§5.U.5): 同上,transport 层断开 = 提示 + Stop 状态,不重连。
                // v1.2.0 (HH) P5: same reconcile-before-giving-up as above for
                // non-AppError transport failures.
                let wasStreaming: Bool = { if case .streaming = self.writingState { return true }; return false }()
                let mapped = AppError.transport(error.localizedDescription)
                if wasStreaming {
                    await self.refreshAfterIncompleteStream(originalError: mapped, onDone: onDone)
                } else {
                    self.writingState = .failed(mapped)
                    self.errorBus.publish(mapped)
                }
            }
        }
    }

    /// GET-and-reconcile after a stream ended without an explicit `.done`.
    ///
    /// v1.2.0 (HH) P5 (🔴#1, reviewer 抓出): this used to promote to `.done`
    /// unconditionally on any successful GET, regardless of whether the
    /// backend actually salvaged a usable draft. That silently swallowed
    /// real failures (e.g. a pre-stream 401/409/429/5xx thrown before any
    /// token arrived — `writingState` is already `.streaming` at that point,
    /// see `startWriting`'s `wasStreaming` check) — the chapter would still
    /// show `prompt_ready`/no draft, yet the store reported `.done` with no
    /// Toast. The GET-failure branch also failed to publish to `errorBus`,
    /// making the .failed transition invisible (Views only pattern-match
    /// `.streaming`; ErrorBus Toast is the only failure-visibility channel).
    ///
    /// Contract (plan §4.1 P5): GET succeeds AND `status == .draftReady` AND
    /// `draftText` is non-empty → `.done`. Otherwise (GET fails, or GET
    /// succeeds but the chapter still shows no usable draft) → maintain
    /// `.failed(originalError)` and publish `originalError` so the failure
    /// is visible.
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
            } else {
                self.writingState = .failed(originalError)
                self.errorBus.publish(originalError)
            }
        } catch {
            self.writingState = .failed(originalError)
            self.errorBus.publish(originalError)
        }
    }

    public func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        if case .streaming = writingState {
            writingState = .idle
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
