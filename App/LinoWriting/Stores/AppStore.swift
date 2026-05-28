import Foundation
import SwiftUI

/// Top-level coordinator. Owns "which book is open" and "do we have settings yet".
@MainActor
public final class AppStore: ObservableObject {

    @Published public var isConfigured: Bool
    @Published public var showSettings: Bool = false

    /// The currently opened book. `nil` means we're on the bookshelf.
    @Published public var currentBook: Book?

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

    /// v0.9 §5.W.5 (W-3): iOS-only launch gate. `true` when the resolved
    /// `baseURL`'s host has no device token in Keychain yet, so the root
    /// view shows the full-screen `DevicePairView` instead of the main UI.
    ///
    /// This is the iOS replacement for the macOS `pendingTokenSetupBanner`
    /// path: macOS is the *pairing source* (author hand-fills a token /
    /// generates codes in SettingsView), so on macOS we keep showing the
    /// first-run SettingsView + banner; on iOS the device must be paired by
    /// scanning / entering a code before the main UI is reachable.
    ///
    /// Predicate is identical to `shouldShowBanner` (URL set, host token
    /// row empty) — kept as a distinct, intent-named accessor so the iOS
    /// root view reads clearly and so a future divergence (e.g. iOS wanting
    /// to gate on something the macOS banner doesn't) is a one-line change.
    public var needsDevicePairing: Bool {
        Self.shouldShowBanner(keychain: keychain)
    }

    /// Called by `DevicePairView` after a successful `pair_confirm` writes
    /// the device token to Keychain. Re-reads Keychain so `isConfigured`
    /// flips → the iOS root view re-routes from the pairing screen to the
    /// bookshelf, and clears the (iOS-irrelevant but harmless) banner flag.
    public func refreshAuthState() {
        isConfigured = keychain.isConfigured
        pendingTokenSetupBanner = Self.shouldShowBanner(keychain: keychain)
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
