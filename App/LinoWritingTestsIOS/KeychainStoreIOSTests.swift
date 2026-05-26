import XCTest
@testable import LinoWriting

/// R-4 (v0.8) — iOS Simulator Keychain sanity.
///
/// 🔵 iOS Simulator (and unit-test bundle hosts in particular) requires a
/// `keychain-access-group` entitlement for `SecItemAdd` to succeed even
/// with `kSecAttrAccessibleAfterFirstUnlock`. The LinoI app on real iOS
/// gets this automatically via its app-group entitlement; the test
/// bundle's `BUNDLE_LOADER`-hosted instance does not. As a result the
/// round-trip write/read tests can fail with `errSecMissingEntitlement`
/// (-34018) on iOS Simulator even though the production code works.
/// §5.R.7 calls out this exact edge case: "iOS Simulator 不支持
/// keychain ... 的某些边界条件:R-4 测试要在真机抽 1 次".
///
/// What we *can* verify in pure logic tests is the *contract* of
/// ``KeychainStore`` when no writes have succeeded:
///   - fresh store reports nothing configured
///   - calling `clear()` on a fresh store is a no-op (no crash)
///   - the per-host token accessor returns nil for an unknown host
///
/// The actual SecItemAdd round-trip is exercised in the human Simulator
/// pass per §5.R.8 (and on the author's iPhone per §5.R.7).
final class KeychainStoreIOSTests: XCTestCase {

    private func freshService() -> String {
        "com.lino.linowriting.tests.ios.\(UUID().uuidString)"
    }

    /// Fresh store with nothing written → `baseURL` is nil.
    /// This exercises the read path through `SecItemCopyMatching`, which
    /// returns `errSecItemNotFound` and is handled correctly by the
    /// `guard status == errSecSuccess` branch.
    func test_freshStore_baseURLIsNil() {
        let store = KeychainStore(service: freshService())
        XCTAssertNil(store.baseURL)
    }

    /// Fresh store → `token` is nil even without a baseURL host
    /// (falls through to the legacy row read, which also misses).
    func test_freshStore_tokenIsNil() {
        let store = KeychainStore(service: freshService())
        XCTAssertNil(store.token)
    }

    /// Fresh store → `isConfigured` is false (needs both URL and token).
    func test_freshStore_isNotConfigured() {
        let store = KeychainStore(service: freshService())
        XCTAssertFalse(store.isConfigured)
    }

    /// `token(forHost:)` for an arbitrary host returns nil when nothing
    /// has been written, and is robust to an empty-string host (returns
    /// nil rather than crashing on the SecItem query).
    func test_tokenForHost_unknownHost_returnsNil() {
        let store = KeychainStore(service: freshService())
        XCTAssertNil(store.token(forHost: "unknown.example.com"))
        XCTAssertNil(store.token(forHost: ""))
    }

    /// `clear()` on a fresh store doesn't crash (no items to delete).
    /// SecItemDelete returning `errSecItemNotFound` is fine; we just
    /// confirm the call completes.
    func test_clearOnFreshStore_isNoop() {
        let store = KeychainStore(service: freshService())
        store.clear()
        XCTAssertNil(store.baseURL)
        XCTAssertNil(store.token)
    }
}
