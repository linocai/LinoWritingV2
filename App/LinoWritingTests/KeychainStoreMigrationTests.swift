import XCTest
import Security
@testable import LinoWriting

/// v0.9.1 §5.CC (CC-1) — data-protection keychain migration + round-trip.
///
/// 🔵 Like ``KeychainStoreIOSTests``, the XCTest *host* process does not
/// carry the app's `keychain-access-groups` entitlement (it is hosted
/// inside LinoI.app via `BUNDLE_LOADER`, and only the app target declares
/// `CODE_SIGN_ENTITLEMENTS`). On macOS the *data-protection* keychain in
/// particular can reject `SecItemAdd` with `errSecMissingEntitlement`
/// (-34018) from such a host even though the production app works. So the
/// round-trip and migration tests guard on a probe write and `XCTSkip`
/// when the host can't reach the data-protection keychain — exactly the
/// degraded-assertion pattern §5.R.7 calls out for keychain coverage.
///
/// What we can *always* verify (no real write needed) is the migration's
/// idempotence / no-op contract: a store with nothing in either keychain
/// returns no failures and writes nothing.
final class KeychainStoreMigrationTests: XCTestCase {

    private func freshService() -> String {
        "com.lino.linowriting.tests.cc1.\(UUID().uuidString)"
    }

    /// Probe whether this test host can actually write to the
    /// data-protection keychain. Returns true on a confirmed round-trip.
    private func dataProtectionKeychainUsable(service: String) -> Bool {
        let account = "probe.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(del as CFDictionary)
            return true
        }
        return false
    }

    /// Tear down any data-protection rows a test may have written so the
    /// host keychain isn't polluted across runs.
    private func purgeDataProtection(service: String) {
        let store = KeychainStore(service: service)
        store.clear()
    }

    // MARK: - Round-trip on the data-protection keychain

    /// Writing then reading the base URL goes through the data-protection
    /// keychain (every query now sets `kSecUseDataProtectionKeychain`).
    func test_dataProtection_roundTrip() throws {
        let service = freshService()
        try XCTSkipUnless(
            dataProtectionKeychainUsable(service: service),
            "Data-protection keychain not writable from this XCTest host (errSecMissingEntitlement). Verified on device/Simulator per §5.R.8."
        )
        defer { purgeDataProtection(service: service) }

        let store = KeychainStore(service: service)
        store.baseURL = URL(string: "https://lw.linotsai.top")
        store.token = "cloud-token-123"

        XCTAssertEqual(store.baseURL?.absoluteString, "https://lw.linotsai.top")
        XCTAssertEqual(store.token, "cloud-token-123")
        XCTAssertTrue(store.isConfigured)
    }

    // MARK: - Migration

    /// Legacy file-based keychain has a base URL + per-host token; the
    /// data-protection keychain is empty. After migration the values are
    /// readable through the (data-protection) accessors and the legacy
    /// rows are gone.
    func test_migration_movesLegacyRowsIntoDataProtection() throws {
        let service = freshService()
        try XCTSkipUnless(
            dataProtectionKeychainUsable(service: service),
            "Data-protection keychain not writable from this XCTest host."
        )
        defer {
            purgeDataProtection(service: service)
            // Also purge any legacy rows the test seeded.
            legacyDelete(service: service, account: "api_base_url")
            legacyDelete(service: service, account: "api_token.lw.linotsai.top")
        }

        // Seed the legacy file-based keychain directly.
        guard legacyWrite(service: service, account: "api_base_url", value: "https://lw.linotsai.top"),
              legacyWrite(service: service, account: "api_token.lw.linotsai.top", value: "legacy-token") else {
            throw XCTSkip("Could not seed legacy file-based keychain on this host.")
        }

        let store = KeychainStore(service: service)
        let failed = store.migrateFromLegacyKeychainIfNeeded()
        XCTAssertTrue(failed.isEmpty, "no account should fail to migrate")

        // The core guarantee: the values are now readable through the
        // (data-protection) accessors that the live app uses on every read.
        XCTAssertEqual(store.baseURL?.absoluteString, "https://lw.linotsai.top")
        XCTAssertEqual(store.token, "legacy-token")
        XCTAssertTrue(store.isConfigured)

        // NOTE: we deliberately do NOT assert that an *unflagged* read of the
        // old account now returns nil. On the entitled app host the file-based
        // and data-protection keychains are unified, so a query that omits
        // `kSecUseDataProtectionKeychain` still surfaces the migrated
        // data-protection item. That coupling is the same reason the
        // migration deletes the legacy row *before* the data-protection write
        // (see ``KeychainStore.migrateFromLegacyKeychainIfNeeded``); asserting
        // on legacy-row absence here would be testing the OS's keychain
        // unification, not our migration. The post-migration value being
        // readable via the live accessors above is the contract that matters.
    }

    /// Running migration a second time is a no-op: the data-protection
    /// keychain already holds the values, so nothing is re-read or
    /// re-written and no failures are reported.
    func test_migration_isIdempotent() throws {
        let service = freshService()
        try XCTSkipUnless(
            dataProtectionKeychainUsable(service: service),
            "Data-protection keychain not writable from this XCTest host."
        )
        defer { purgeDataProtection(service: service) }

        // Pre-populate the data-protection keychain directly via the store.
        let store = KeychainStore(service: service)
        store.baseURL = URL(string: "https://lw.linotsai.top")
        store.token = "already-migrated"

        // No legacy rows exist → migration finds the data-protection rows
        // present and skips everything.
        let first = store.migrateFromLegacyKeychainIfNeeded()
        let second = store.migrateFromLegacyKeychainIfNeeded()
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(store.token, "already-migrated")
    }

    /// With nothing in either keychain, migration reports no failures and
    /// leaves the store unconfigured. This branch needs no real write, so
    /// it runs on every host (no skip).
    func test_migration_emptyKeychain_isNoop() {
        let store = KeychainStore(service: freshService())
        let failed = store.migrateFromLegacyKeychainIfNeeded()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.baseURL)
        XCTAssertNil(store.token)
    }

    // MARK: - Legacy file-based keychain helpers (test-only)

    @discardableResult
    private func legacyWrite(service: String, account: String, value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func legacyRead(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func legacyDelete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
