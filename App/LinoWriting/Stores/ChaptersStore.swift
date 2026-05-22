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
}
