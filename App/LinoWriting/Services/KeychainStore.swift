import Foundation
import Security

/// Stores the API base URL and bearer token(s) in the macOS / iOS Keychain.
///
/// v0.8 §5.U.2 changed the token storage to be **per-host**: when the
/// author switches `baseURL` from `http://localhost:8787` to
/// `https://lw.linotsai.top`, the dev token stays put and a fresh slot is
/// allocated for the new host. This matches the §5.U.3 decision A
/// ("two-don't, prompt once"): we never auto-migrate or auto-clear, just
/// surface a banner asking for the cloud token the first time the host
/// has no entry.
///
/// Layout:
///   - service `com.lino.linowriting`
///   - account `api_base_url`            → the URL string
///   - account `api_token`               → **legacy** single-row token (kept for
///                                          back-compat with v0.7 macOS installs;
///                                          read as fallback when the per-host row
///                                          is empty, never written by new code)
///   - account `api_token.<host>`        → v0.8 per-host token; one row per host
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    private let service: String
    private let baseURLKey = "api_base_url"
    private let legacyTokenKey = "api_token"

    public init(service: String = "com.lino.linowriting") {
        self.service = service
    }

    // MARK: - Public

    public var baseURL: URL? {
        get { read(baseURLKey).flatMap { URL(string: $0) } }
        set { write(baseURLKey, newValue?.absoluteString) }
    }

    /// Token for the **current** `baseURL`'s host. v0.8 §5.U.2.
    ///
    /// Reads:
    ///   1. per-host row `api_token.<host>` if present
    ///   2. legacy single-row `api_token` as fallback (so existing v0.7
    ///      macOS installs continue to work when the author keeps using
    ///      the same backend)
    ///
    /// Writes always go to the per-host row; legacy row is never touched
    /// by new code so the author's localhost dev credentials survive a
    /// host switch.
    public var token: String? {
        get {
            if let host = baseURL?.host, !host.isEmpty,
               let perHost = read(tokenKey(forHost: host)) {
                return perHost
            }
            return read(legacyTokenKey)
        }
        set {
            guard let host = baseURL?.host, !host.isEmpty else {
                // No host yet — should only happen in the first-run flow
                // where the URL field is empty. Stash into the legacy
                // row so we don't drop the value; the saveCredentials
                // call site always sets URL first, so in practice this
                // branch is dead.
                write(legacyTokenKey, newValue)
                return
            }
            write(tokenKey(forHost: host), newValue)
        }
    }

    /// Per-host token accessor — exposed for the network self-test UI and
    /// the §5.U.2 banner trigger. `host` is typically `baseURL?.host`.
    public func token(forHost host: String) -> String? {
        guard !host.isEmpty else { return nil }
        return read(tokenKey(forHost: host))
    }

    public var isConfigured: Bool {
        guard let url = baseURL, !(url.absoluteString.isEmpty), let t = token, !t.isEmpty else { return false }
        return true
    }

    /// Clears the URL and all token rows we know about (current host +
    /// legacy). Per-host rows for other hosts are left in place — the
    /// author switches between localhost and prod often enough that a
    /// nuke-everything would be hostile.
    public func clear() {
        if let host = baseURL?.host, !host.isEmpty {
            write(tokenKey(forHost: host), nil)
        }
        write(legacyTokenKey, nil)
        write(baseURLKey, nil)
    }

    // MARK: - Internal helpers

    /// Account key pattern documented at the top of the file. Kept
    /// `internal` so tests can assert the exact storage layout if
    /// future refactors swap providers.
    private func tokenKey(forHost host: String) -> String {
        // PROJECT_PLAN §5.U.2 wording: `lino.{host}.token`. We honour the
        // intent (per-host) but stick with the `api_token.` prefix that
        // matches the legacy account name so all our entries share a
        // discoverable prefix in Keychain Access.app.
        return "api_token.\(host)"
    }

    // MARK: - Private SecItem helpers

    private func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Always wipe first to keep the call site simple.
        SecItemDelete(baseQuery as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
