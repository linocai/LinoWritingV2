import Foundation
import SwiftUI

/// Top-level coordinator. Owns "which book is open" and "do we have settings yet".
@MainActor
public final class AppStore: ObservableObject {

    @Published public var isConfigured: Bool
    @Published public var showSettings: Bool = false

    /// The currently opened book. `nil` means we're on the bookshelf.
    @Published public var currentBook: Book?

    private let keychain: KeychainStore
    private let settings: Settings

    public init(keychain: KeychainStore, settings: Settings) {
        self.keychain = keychain
        self.settings = settings
        self.isConfigured = keychain.isConfigured
    }

    /// Persist new credentials. Triggers `isConfigured` flip → RootView re-route.
    public func saveCredentials(baseURL: URL, token: String) {
        keychain.baseURL = baseURL
        keychain.token = token
        isConfigured = keychain.isConfigured
        showSettings = false
    }

    public func clearCredentials() {
        keychain.clear()
        isConfigured = false
        currentBook = nil
    }

    public func openBook(_ book: Book) {
        currentBook = book
        settings.lastOpenedBookId = book.id
    }

    public func closeBook() {
        currentBook = nil
    }

    /// Update the in-memory book metadata (e.g., after a PATCH).
    public func updateCurrentBook(_ book: Book) {
        if currentBook?.id == book.id { currentBook = book }
    }
}
