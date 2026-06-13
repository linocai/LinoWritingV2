import Foundation
import SwiftUI

/// v1.0.0 EE §5.5 — backs the book-level 大纲面板 (outline panel).
///
/// Three operations, **no digest** (the outline is plain prose — §5.1):
///   - `load(bookId:)`           → `GET /books/{id}/outline` (may be nil)
///   - `ingest(bookId:rawText:)` → `POST /books/{id}/outline/ingest` (upsert)
///   - `patch(bookId:rawText:)`  → `PATCH /books/{id}/outline` (living edit)
///
/// Follows the conservative "reload-after-mutation is unnecessary because the
/// endpoint returns the fresh row" + ErrorBus pattern used across the app:
/// every failed call publishes to the bus and leaves prior state untouched;
/// every success replaces `outline` with the server's authoritative copy.
@MainActor
public final class OutlineStore: ObservableObject {

    /// The currently-loaded book's outline, or `nil` when the book has never
    /// ingested one (or hasn't been loaded yet).
    @Published public private(set) var outline: BookOutline?
    /// Which book `outline` belongs to — guards against a late load() landing
    /// after the user switched books.
    @Published public private(set) var loadedBookId: String?
    @Published public private(set) var isLoading: Bool = false
    /// True while an ingest / patch call is in flight; disables the save button.
    @Published public private(set) var isSaving: Bool = false

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    /// Convenience accessor for the panel: the verbatim outline text (or "").
    public var rawText: String {
        outline?.rawText ?? ""
    }

    public func load(bookId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.getOutline(bookId: bookId)
            self.outline = fetched
            self.loadedBookId = bookId
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// 摄入：upsert the outline body. The author pastes their ~5000-word prose
    /// and saves. Returns the stored outline on success (also assigned to
    /// `outline`), or `nil` on failure (already published to ErrorBus).
    @discardableResult
    public func ingest(bookId: String, rawText: String?) async -> BookOutline? {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await api.ingestOutline(bookId: bookId, rawText: rawText)
            self.outline = saved
            self.loadedBookId = bookId
            return saved
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// 保存修改：the living-outline hand-edit (whitelist `raw_text`). Backend
    /// upserts when the book never ingested, so this is equally valid as a
    /// first save; the panel uses `ingest` for the摄入 path and `patch` for the
    /// 回看-then-edit path purely to mirror the §5.1 endpoint split.
    @discardableResult
    public func patch(bookId: String, rawText: String?) async -> BookOutline? {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await api.patchOutline(bookId: bookId, rawText: rawText)
            self.outline = saved
            self.loadedBookId = bookId
            return saved
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// Wipe in-memory state — called when leaving a book so the next book's
    /// panel doesn't briefly show a stale outline.
    public func reset() {
        outline = nil
        loadedBookId = nil
    }
}
