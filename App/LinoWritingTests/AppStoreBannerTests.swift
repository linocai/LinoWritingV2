import XCTest
@testable import LinoWriting

/// v0.8 §5.U.6 acceptance: "iOS XCTest 加 1 个测试: 启动时若 host 无 token,
/// AppStore 触发 `pendingTokenSetupBanner = true`"。
///
/// We use a custom Keychain service id so these tests don't trample the
/// author's real Keychain entries when run locally, then assert the
/// three states the banner predicate must cover:
///
///   1. Fresh install (no URL, no token) → AppStore seeds the production
///      default URL into Keychain, and because that host has no token
///      row yet, banner is `true`.
///   2. URL + token both present for the same host → banner is `false`.
///   3. URL present, token row for that host empty → banner is `true`.
@MainActor
final class AppStoreBannerTests: XCTestCase {

    /// Each test gets its own service id to keep them hermetic.
    private func makeKeychain(suffix: String = UUID().uuidString) -> KeychainStore {
        KeychainStore(service: "com.lino.linowriting.tests.\(suffix)")
    }

    /// Cleans up the URL + every token row this keychain could've written.
    private func wipe(_ keychain: KeychainStore) {
        keychain.clear()
    }

    func test_freshInstall_seedsDefaultURL_andTripsBanner() {
        let keychain = makeKeychain()
        defer { wipe(keychain) }
        // Fresh install: keychain is empty.
        XCTAssertNil(keychain.baseURL)
        XCTAssertNil(keychain.token)

        let store = AppStore(keychain: keychain, settings: Settings())

        // §5.U.2: production default seeded on first launch.
        XCTAssertEqual(keychain.baseURL?.absoluteString, Settings.defaultBackendURLString)
        // §5.U.6: no token for the new host → banner asks for it.
        XCTAssertTrue(store.pendingTokenSetupBanner)
        // And we're not "configured" yet — RootView routes to first-run.
        XCTAssertFalse(store.isConfigured)
    }

    func test_existingHostWithToken_doesNotShowBanner() {
        let keychain = makeKeychain()
        defer { wipe(keychain) }
        let url = URL(string: "https://lw.linotsai.top")!
        keychain.baseURL = url
        keychain.token = "fake-token"

        let store = AppStore(keychain: keychain, settings: Settings())

        XCTAssertFalse(store.pendingTokenSetupBanner)
        XCTAssertTrue(store.isConfigured)
    }

    func test_saveCredentials_clearsBanner() {
        let keychain = makeKeychain()
        defer { wipe(keychain) }
        let store = AppStore(keychain: keychain, settings: Settings())
        XCTAssertTrue(store.pendingTokenSetupBanner)

        store.saveCredentials(
            baseURL: URL(string: "https://lw.linotsai.top")!,
            token: "new-token"
        )

        XCTAssertFalse(store.pendingTokenSetupBanner)
        XCTAssertTrue(store.isConfigured)
    }

    func test_perHostTokenIsolation() {
        let keychain = makeKeychain()
        defer { wipe(keychain) }
        // Set the dev (localhost) creds first.
        keychain.baseURL = URL(string: "http://localhost:8787")
        keychain.token = "dev-token"
        XCTAssertEqual(keychain.token, "dev-token")

        // Switch to prod host; per-host token slot is fresh, so token is nil.
        keychain.baseURL = URL(string: "https://lw.linotsai.top")
        XCTAssertNil(keychain.token, "switching host should not surface the dev token")

        // Write prod token; switching back to dev should still return dev-token.
        keychain.token = "prod-token"
        XCTAssertEqual(keychain.token, "prod-token")

        keychain.baseURL = URL(string: "http://localhost:8787")
        XCTAssertEqual(keychain.token, "dev-token", "dev token must survive a host switch")
    }
}
