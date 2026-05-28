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

    /// v0.9.1 §5.CC: every query now opts into the **data-protection
    /// keychain** (`kSecUseDataProtectionKeychain: true`). On macOS this
    /// switches us off the file-based login keychain (interactive ACL =
    /// password prompt) and onto the iOS-style keychain that is gated by
    /// the `keychain-access-groups` entitlement instead of a prompt → zero
    /// dialogs after the one-time migration. On iOS this is already the
    /// only keychain, so it is a no-op there.
    ///
    /// We deliberately do **not** set `kSecAttrAccessGroup` explicitly:
    /// the app's entitlement declares exactly one access group
    /// (`$(AppIdentifierPrefix)com.lino.linowriting.LinoWriting`), which
    /// the system uses as the default group for both reads and writes.
    /// That keeps read/write/delete consistent without hardcoding the
    /// Team ID prefix here, and lets headless test hosts (which lack the
    /// entitlement) fall back to their own default group instead of
    /// failing with `errSecMissingEntitlement`.
    private func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
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
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        // Always wipe first to keep the call site simple.
        SecItemDelete(baseQuery as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - v0.9.1 §5.CC one-time legacy → data-protection migration

    /// Migrates generic-password items from the **legacy file-based login
    /// keychain** (no `kSecUseDataProtectionKeychain`) into the
    /// data-protection keychain that the rest of this type now reads/writes.
    ///
    /// macOS only carried a file-based keychain before v0.9.1; on iOS the
    /// data-protection keychain is the only one, so the legacy enumeration
    /// finds nothing and this is a harmless no-op.
    ///
    /// Safety contract (§5.CC.2) — with a macOS-specific ordering twist:
    ///   - read the legacy item first (this single read may trigger **one
    ///     last** ACL prompt on macOS, which is expected/acceptable); if we
    ///     can't read it there is nothing to migrate, so we never destroy
    ///     anything we couldn't first capture,
    ///   - **delete the legacy item, then** write the captured value into
    ///     the data-protection keychain and verify.
    ///
    /// Why delete *before* the final write? On an **entitled** macOS app the
    /// file-based and data-protection keychains are not cleanly separable: a
    /// `SecItemDelete` that omits `kSecUseDataProtectionKeychain` (our
    /// "legacy" delete) also removes a matching data-protection item. So a
    /// "write-DP → delete-legacy" order would clobber the value we just
    /// migrated. Doing the legacy delete first and the data-protection write
    /// (which itself delete-then-adds *with* the DP flag) last leaves the
    /// value safely in the data-protection keychain. We only delete after a
    /// successful in-memory `legacyRead`, so the value is never lost: a
    /// failed DP write surfaces in the returned `failed` list and the author
    /// can re-enter the token.
    ///
    /// Idempotent: an account that already exists in the data-protection
    /// keychain (and has no legacy row left to read) is skipped, so
    /// re-running on later launches does nothing.
    ///
    /// - Returns: the legacy accounts whose data-protection write could not
    ///   be confirmed. Callers run on the main actor and can surface these
    ///   via `ErrorBus`; on the happy path this is empty. `KeychainStore`
    ///   stays free of any `@MainActor` / `ErrorBus` coupling so it can be
    ///   exercised off the main thread and in headless tests.
    @discardableResult
    public func migrateFromLegacyKeychainIfNeeded() -> [String] {
        var failed: [String] = []
        for account in legacyAccounts() {
            // Capture the legacy value first. `legacyRead` is a file-based
            // query; if there is genuinely nothing to migrate (fresh
            // install / iOS / already-migrated where the legacy row is
            // gone) this returns nil and we skip — nothing is destroyed.
            guard let value = legacyRead(account) else { continue }
            // Remove the legacy row up front. On an entitled macOS app this
            // also clears any unified data-protection copy, which is fine
            // because we re-write it below.
            legacyDelete(account)
            // Write into the data-protection keychain (delete-then-add with
            // the DP flag) and verify it landed.
            guard writeDataProtection(account, value), read(account) == value else {
                // Could not confirm the data-protection write. We still hold
                // `value` in memory; report the account up so the author can
                // re-enter the token in Settings.
                failed.append(account)
                continue
            }
        }
        return failed
    }

    /// The set of legacy file-based accounts to migrate.
    ///
    /// We try a `kSecMatchLimitAll` enumeration first (it sweeps up *every*
    /// `api_token.<host>` per-host row when it works), but on the **entitled
    /// app** macOS keychain that bulk query is unreliable — a process that
    /// carries the `keychain-access-groups` entitlement gets an empty result
    /// from a `kSecMatchLimitAll` query against the *file-based* keychain,
    /// even though a single-item `kSecMatchLimitOne` read of the same account
    /// succeeds. So we always also include a deterministic set derived from
    /// single-item reads:
    ///   - `api_base_url` (the URL row),
    ///   - `api_token` (legacy single-row token),
    ///   - `api_token.<host>` for the host of the legacy `api_base_url`
    ///     (covers the author's real single-prod-host setup; localhost is
    ///     picked up by the enumeration when it works, or is simply a dev
    ///     row the author can re-pair).
    /// The union is de-duplicated so an account isn't migrated twice.
    private func legacyAccounts() -> [String] {
        var accounts = Set(enumerateLegacyAccounts())
        // Deterministic fallbacks that don't rely on the flaky bulk query.
        accounts.insert(baseURLKey)
        accounts.insert(legacyTokenKey)
        if let urlString = legacyRead(baseURLKey),
           let host = URL(string: urlString)?.host, !host.isEmpty {
            accounts.insert(tokenKey(forHost: host))
        }
        return Array(accounts)
    }

    /// Best-effort `kSecMatchLimitAll` enumeration of every generic-password
    /// account under our `service` in the **legacy file-based** keychain.
    /// Returns `[]` when the bulk query is rejected (entitled-app quirk,
    /// see ``legacyAccounts()``); the deterministic fallbacks there still
    /// cover the author's real layout.
    private func enumerateLegacyAccounts() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
            // No kSecUseDataProtectionKeychain → file-based keychain.
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        let items = (result as? [[String: Any]]) ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Reads a single account from the legacy file-based keychain.
    private func legacyRead(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
            // No kSecUseDataProtectionKeychain → file-based keychain.
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a single account from the legacy file-based keychain.
    private func legacyDelete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
            // No kSecUseDataProtectionKeychain → file-based keychain.
        ]
        SecItemDelete(q as CFDictionary)
    }

    /// Writes a value into the data-protection keychain, returning whether
    /// the add succeeded. Mirrors ``write(_:_:)`` but reports the status so
    /// migration can gate the legacy delete on a confirmed write.
    @discardableResult
    private func writeDataProtection(_ account: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
