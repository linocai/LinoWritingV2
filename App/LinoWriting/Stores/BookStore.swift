import Foundation
import SwiftUI

/// Holds the currently-open book's metadata and coordinates child stores'
/// load() calls when the active book changes.
@MainActor
public final class BookStore: ObservableObject {

    @Published public private(set) var book: Book?

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    public func setBook(_ book: Book) {
        self.book = book
    }

    public func reload() async {
        guard let book else { return }
        do {
            let updated = try await api.getBook(id: book.id)
            self.book = updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func patchWorldSetting(_ value: String) async {
        await patch(BookPatchRequest(worldSetting: value))
    }

    public func patchStyleDirective(_ value: String) async {
        await patch(BookPatchRequest(styleDirective: value))
    }

    public func patchTitle(_ value: String) async {
        await patch(BookPatchRequest(title: value))
    }

    public func patchCoverColor(_ value: String) async {
        await patch(BookPatchRequest(coverColor: value))
    }

    private func patch(_ payload: BookPatchRequest) async {
        guard let book else { return }
        do {
            let updated = try await api.patchBook(id: book.id, payload)
            self.book = updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }
}
