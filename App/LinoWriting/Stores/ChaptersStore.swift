import Foundation
import SwiftUI

@MainActor
public final class ChaptersStore: ObservableObject {

    @Published public private(set) var chapters: [ChapterSummary] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var selectedChapterId: String?
    @Published public var showNewChapterSheet: Bool = false
    /// Cached chapter summaries keyed by chapter id, for the Summaries tab.
    @Published public private(set) var summaryTexts: [String: String] = [:]

    private let api: APIClientProtocol
    private let errorBus: ErrorBus
    private var currentBookId: String?

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    public var sorted: [ChapterSummary] {
        chapters.sorted { $0.index < $1.index }
    }

    public func load(bookId: String) async {
        currentBookId = bookId
        isLoading = true
        defer { isLoading = false }
        do {
            chapters = try await api.listChapters(bookId: bookId)
            if selectedChapterId == nil { selectedChapterId = sorted.first?.id }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func reset() {
        chapters = []
        selectedChapterId = nil
        currentBookId = nil
    }

    public func create(userPrompt: String?, title: String?) async -> Chapter? {
        guard let bookId = currentBookId else { return nil }
        do {
            let new = try await api.createChapter(
                bookId: bookId,
                ChapterCreateRequest(userPrompt: userPrompt, title: title)
            )
            chapters.append(new.summaryShape)
            selectedChapterId = new.id
            showNewChapterSheet = false
            return new
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    public func delete(id: String) async {
        do {
            try await api.deleteChapter(id: id)
            chapters.removeAll { $0.id == id }
            if selectedChapterId == id {
                selectedChapterId = sorted.first?.id
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// Update the local summary list after a chapter mutation.
    public func upsert(_ chapter: Chapter) {
        if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
            chapters[idx] = chapter.summaryShape
        } else {
            chapters.append(chapter.summaryShape)
        }
    }

    public func upsertSummary(_ summary: ChapterSummary) {
        if let idx = chapters.firstIndex(where: { $0.id == summary.id }) {
            chapters[idx] = summary
        } else {
            chapters.append(summary)
        }
    }

    /// Fetch the full chapter detail to populate the summary cache. Idempotent.
    public func ensureSummary(chapterId: String) async {
        guard summaryTexts[chapterId] == nil else { return }
        do {
            let detail = try await api.getChapter(id: chapterId)
            if let text = detail.summary { summaryTexts[chapterId] = text }
        } catch {
            // Soft-fail; the row will keep showing "加载中…" or empty.
        }
    }

    /// Publish a batch-level error message to the shared bus (used by
    /// `NewChapterSheet` when **every** chapter in a batch failed and
    /// the sheet wants to surface a single aggregated toast instead of
    /// the failure-summary dialog). Wraps `errorBus.publish` so callers
    /// don't need a direct handle to the bus.
    public func errorBusPublishFromBatch(_ message: String) {
        errorBus.publish(message, critical: false)
    }

    /// Batch create + import a list of `ParsedChapter`s in source order
    /// (PROJECT_PLAN v0.7 §5.O batch import).
    ///
    /// **Sequential, not parallel.** Three reasons:
    ///   1. The Extractor runs LLM calls per chapter; firing 50 in
    ///      parallel will instantly hit any provider's rate limit and
    ///      cause cascading 429s.
    ///   2. The backend's `extractor_apply` writes character live_fields
    ///      and timeline events; two concurrent imports against the
    ///      same book would race on `pending_field_highlights` JSONB.
    ///   3. The status state machine on `chapters` table is per-chapter,
    ///      but the progress callback semantics ("第 N 章导入中…") would
    ///      be meaningless if all 50 returned at once.
    ///
    /// **Failure handling: continue, don't stop.** If chapter 23 fails
    /// (network blip, LLM 429, 409 status conflict), we keep going so
    /// 24..N still land. Each failure is recorded as `.failure(AppError)`
    /// in the returned array; the caller is expected to surface "N/M
    /// 章失败" UI from the result list. **No** ErrorBus publish here —
    /// the caller decides whether one transient failure should toast or
    /// only the aggregated end-of-batch dialog should.
    ///
    /// Side effects:
    ///   - Successful chapters are `upsert`ed into `self.chapters` as
    ///     they finish, so the sidebar list grows in real time while
    ///     the import is running (gives the user visual feedback).
    ///   - `selectedChapterId` is **not** changed; the user stays on
    ///     whatever chapter they were viewing.
    ///   - `progress` is called on the main actor after each chapter
    ///     completes (success or failure). The first call comes after
    ///     the first chapter, so the UI shows "1/N" rather than "0/N"
    ///     at the start.
    public func batchCreateAndImport(
        parsedChapters: [ParsedChapter],
        runExtractor: Bool,
        progress: @MainActor (Int, Int) -> Void
    ) async -> [Result<Chapter, AppError>] {
        guard let bookId = currentBookId else { return [] }
        let total = parsedChapters.count
        var results: [Result<Chapter, AppError>] = []

        for (i, parsed) in parsedChapters.enumerated() {
            let outcome = await createAndImportOne(
                bookId: bookId,
                parsed: parsed,
                runExtractor: runExtractor
            )
            results.append(outcome)
            // Reflect success to the sidebar immediately. Failures are
            // not appended — they have no chapter to show.
            if case .success(let chapter) = outcome {
                upsert(chapter)
            }
            progress(i + 1, total)
        }
        return results
    }

    /// One step of `batchCreateAndImport`: POST /chapters → POST /import.
    /// Pulled out so the loop body stays readable and the two-call
    /// failure surface ("createChapter failed" vs "importChapter
    /// failed") is uniform — either error maps to the same
    /// `Result.failure(AppError)` shape with the message preserved.
    private func createAndImportOne(
        bookId: String,
        parsed: ParsedChapter,
        runExtractor: Bool
    ) async -> Result<Chapter, AppError> {
        let create = ChapterCreateRequest(userPrompt: "", title: parsed.title)
        let created: Chapter
        do {
            created = try await api.createChapter(bookId: bookId, create)
        } catch let error as AppError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        let importPayload = ChapterImportRequest(
            draftText: parsed.body,
            title: parsed.title,
            summary: nil,
            runExtractor: runExtractor
        )
        do {
            let response = try await api.importChapter(id: created.id, payload: importPayload)
            return .success(response.chapter)
        } catch let error as AppError {
            // The skeleton chapter we just created still exists on the
            // backend with empty draft_text. Leave it — the user may
            // want to retry just that one chapter via the per-chapter
            // import sheet, and silently deleting it would lose the
            // `chapters.index` slot they're expecting. Sidebar shows
            // the empty draft row from `upsert` below the failure list.
            upsert(created)
            return .failure(error)
        } catch {
            upsert(created)
            return .failure(.transport(error.localizedDescription))
        }
    }
}
