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
    @Published public private(set) var isExpanding: Bool = false
    @Published public private(set) var isFinalizing: Bool = false

    /// IDs the latest finalize call modified — exposed for the right panel highlight.
    @Published public private(set) var lastFinalizeUpdatedCharacterIds: [String] = []

    private let api: APIClientProtocol
    private let errorBus: ErrorBus
    private var streamTask: Task<Void, Never>?

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    // MARK: Loading

    public func load(chapterId: String) async {
        cancelStream()
        isLoading = true
        defer { isLoading = false }
        do {
            let chapter = try await api.getChapter(id: chapterId)
            self.chapter = chapter
            self.writingState = .idle
        } catch let error as AppError {
            errorBus.publish(error)
            self.chapter = nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func reset() {
        cancelStream()
        chapter = nil
        writingState = .idle
        isExpanding = false
        isFinalizing = false
        lastFinalizeUpdatedCharacterIds = []
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
                    await self.refreshAfterIncompleteStream(onDone: onDone)
                }
            } catch let error as AppError {
                self.writingState = .failed(error)
                if error != .cancelled { self.errorBus.publish(error) }
            } catch {
                let mapped = AppError.transport(error.localizedDescription)
                self.writingState = .failed(mapped)
                self.errorBus.publish(mapped)
            }
        }
    }

    private func refreshAfterIncompleteStream(onDone: (@MainActor (Chapter) -> Void)?) async {
        guard let chapter else {
            writingState = .failed(.upstream("写作中断", retryable: true))
            return
        }
        do {
            let refreshed = try await api.getChapter(id: chapter.id)
            self.chapter = refreshed
            self.writingState = .done
            onDone?(refreshed)
        } catch {
            self.writingState = .failed(.upstream("写作中断，可点重新生成", retryable: true))
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
            self.lastFinalizeUpdatedCharacterIds = result.updatedCharacterIds
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
}
