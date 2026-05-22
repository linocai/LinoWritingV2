import Foundation
import SwiftUI

@MainActor
public final class BookshelfStore: ObservableObject {

    @Published public private(set) var books: [Book] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var showNewBookSheet: Bool = false

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    /// Books sorted for the bookshelf UI: most recently opened first, falling back to updatedAt.
    public var sortedBooks: [Book] {
        books.sorted { a, b in
            let aKey = a.lastOpenedAt ?? a.updatedAt
            let bKey = b.lastOpenedAt ?? b.updatedAt
            return aKey > bKey
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            books = try await api.listBooks()
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func create(title: String, coverColor: String?) async -> Book? {
        do {
            let book = try await api.createBook(BookCreateRequest(title: title, coverColor: coverColor))
            books.insert(book, at: 0)
            showNewBookSheet = false
            return book
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    public func touch(_ book: Book) async {
        do { try await api.touchBook(id: book.id) }
        catch { /* best-effort, ignore */ }
    }

    public func delete(_ book: Book) async {
        do {
            try await api.deleteBook(id: book.id)
            books.removeAll { $0.id == book.id }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func patch(_ book: Book, _ payload: BookPatchRequest) async {
        do {
            let updated = try await api.patchBook(id: book.id, payload)
            if let idx = books.firstIndex(where: { $0.id == book.id }) {
                books[idx] = updated
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }
}
