import Foundation
import SwiftUI

/// Top-level coordinator. Owns "which book is open" and "do we have settings yet".
@MainActor
public final class AppStore: ObservableObject {

    @Published public var isConfigured: Bool
    @Published public var showSettings: Bool = false

    /// The currently opened book. `nil` means we're on the bookshelf.
    @Published public var currentBook: Book?

    /// v1.1.0 (FF) — reader overlay state. When non-nil the macOS shell renders
    /// the reading page (`ReaderView`, Phase 4) on top of the workspace for that
    /// chapter; the workspace stays mounted underneath so returning lands back
    /// on the same chapter. macOS-only consumer; iOS ignores it.
    @Published public var readingChapterId: String?

    /// v0.8 §5.U.2 / §5.U.6: surfaced at the top of the Connection
    /// settings tab when the resolved `baseURL` has no token in Keychain.
    /// Trips on first launch after the default URL flipped from localhost
    /// to `https://lw.linotsai.top` (no token yet) and any time the
    /// author types a new host without filling the token field. The
    /// SettingsView observes this and renders a red banner asking the
    /// author to fill in the cloud token.
    @Published public var pendingTokenSetupBanner: Bool = false

    private let keychain: KeychainStore
    private let settings: Settings

    public init(keychain: KeychainStore, settings: Settings) {
        self.keychain = keychain
        self.settings = settings

        // v0.8 §5.U.2: seed Keychain with the production default the first
        // time LinoI launches on a machine with no prior baseURL. This is
        // what makes the app "open-the-box ready" — the author no longer
        // has to type a URL on a fresh install, only an API token.
        // Existing macOS dev installs that already point at
        // `http://localhost:8787` are untouched because `keychain.baseURL`
        // is non-nil for them.
        if keychain.baseURL == nil,
           let defaultURL = URL(string: Settings.defaultBackendURLString) {
            keychain.baseURL = defaultURL
        }

        self.isConfigured = keychain.isConfigured
        // Banner trips when a URL is set but the token row for that host
        // is empty — exactly the post-default-seed state described above
        // and the "author switched host, token row is fresh" state.
        self.pendingTokenSetupBanner = Self.shouldShowBanner(keychain: keychain)
    }

    /// Persist new credentials. Triggers `isConfigured` flip → RootView re-route.
    public func saveCredentials(baseURL: URL, token: String) {
        keychain.baseURL = baseURL
        keychain.token = token
        isConfigured = keychain.isConfigured
        pendingTokenSetupBanner = Self.shouldShowBanner(keychain: keychain)
        showSettings = false
    }

    public func clearCredentials() {
        keychain.clear()
        isConfigured = false
        currentBook = nil
        pendingTokenSetupBanner = Self.shouldShowBanner(keychain: keychain)
    }

    public func openBook(_ book: Book) {
        currentBook = book
    }

    public func closeBook() {
        currentBook = nil
        readingChapterId = nil
    }

    /// v1.1.0 (FF) — enter the reading overlay for `chapterId`. No-op when nil.
    public func openReader(chapterId: String?) {
        guard let chapterId else { return }
        readingChapterId = chapterId
    }

    /// v1.1.0 (FF) — leave the reading overlay, back to the workspace.
    public func closeReader() {
        readingChapterId = nil
    }

    /// Update the in-memory book metadata (e.g., after a PATCH).
    public func updateCurrentBook(_ book: Book) {
        if currentBook?.id == book.id { currentBook = book }
    }

    /// Banner predicate: URL is set, but the host has no token row.
    /// Exposed as `internal static` so the SettingsView and the v0.8
    /// XCTest in `AppStoreBannerTests.swift` can share the exact same
    /// definition; nothing outside the module needs it.
    static func shouldShowBanner(keychain: KeychainStore) -> Bool {
        guard let url = keychain.baseURL,
              let host = url.host,
              !host.isEmpty
        else { return false }
        let perHostToken = keychain.token(forHost: host)
        return perHostToken == nil || perHostToken?.isEmpty == true
    }
}
