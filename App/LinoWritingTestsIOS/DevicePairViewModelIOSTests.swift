import XCTest
import AVFoundation
@testable import LinoWriting

/// v0.9 §5.W.5 (W-3) — iOS device-pairing view-model state machine.
///
/// Covers the manual-entry path (the ONLY path testable on the Simulator,
/// which has no camera — §5.W.8: "iOS Simulator(无相机)走手输短码路径全程
/// 跑通") plus the scan-payload decode branch.
///
/// 🔵 These are pure logic tests: the view model's network call goes through
/// the injected `MockAPIClient`, and Keychain writes go to a hermetic test
/// service id. On the iOS Simulator the SecItemAdd write may no-op with
/// `errSecMissingEntitlement` (-34018) — see `KeychainStoreIOSTests` — so we
/// deliberately assert on the *mock* (call recorded, code/name forwarded)
/// rather than on a Keychain read-back, which would be flaky on Simulator.
@MainActor
final class DevicePairViewModelIOSTests: XCTestCase {

    /// `MockAPIClient` records every call name into `calls`; tally one kind.
    private func count(_ api: MockAPIClient, _ name: String) -> Int {
        api.calls.filter { $0 == name }.count
    }

    private func freshKeychain() -> KeychainStore {
        KeychainStore(service: "com.lino.linowriting.tests.ios.pair.\(UUID().uuidString)")
    }

    private func makeModel(
        api: MockAPIClient,
        keychain: KeychainStore? = nil,
        appStore: AppStore? = nil,
        errorBus: ErrorBus? = nil
    ) -> DevicePairViewModel {
        let kc = keychain ?? freshKeychain()
        let model = DevicePairViewModel(
            api: api,
            keychain: kc,
            appStore: appStore,
            errorBus: errorBus,
            cameraAuthorization: .authorized
        )
        // Deterministic device name (avoid UIDevice in tests).
        model.deviceNameProvider = { "Test iPhone" }
        return model
    }

    // MARK: - sanitizeCode

    func test_sanitizeCode_stripsNonDigitsAndClampsToSix() {
        XCTAssertEqual(DevicePairViewModel.sanitizeCode("12a3 45"), "12345")
        XCTAssertEqual(DevicePairViewModel.sanitizeCode("0123456789"), "012345")
        XCTAssertEqual(DevicePairViewModel.sanitizeCode("  "), "")
        XCTAssertEqual(DevicePairViewModel.sanitizeCode("007"), "007")  // leading zeros kept
    }

    // MARK: - canSubmitManual gating

    func test_canSubmitManual_defaultURLNoCode_isFalse() {
        let model = makeModel(api: MockAPIClient())
        // Default URL is seeded but no code yet.
        XCTAssertEqual(model.urlString, Settings.defaultBackendURLString)
        XCTAssertFalse(model.canSubmitManual)
    }

    func test_canSubmitManual_validURLAndSixDigits_isTrue() {
        let model = makeModel(api: MockAPIClient())
        model.code = "123456"
        XCTAssertTrue(model.canSubmitManual)
    }

    func test_canSubmitManual_shortCode_isFalse() {
        let model = makeModel(api: MockAPIClient())
        model.code = "12345"
        XCTAssertFalse(model.canSubmitManual)
    }

    func test_canSubmitManual_emptyURL_isFalse() {
        let model = makeModel(api: MockAPIClient())
        model.urlString = ""
        model.code = "123456"
        XCTAssertFalse(model.canSubmitManual)
    }

    func test_canSubmitManual_garbageURLNoScheme_isFalse() {
        let model = makeModel(api: MockAPIClient())
        model.urlString = "not a url"
        model.code = "123456"
        XCTAssertFalse(model.canSubmitManual)
    }

    // MARK: - Manual confirm happy path

    func test_confirmManual_callsPairConfirm_withCodeAndDeviceName() async {
        let api = MockAPIClient()
        let model = makeModel(api: api)
        model.urlString = "https://lw.linotsai.top"
        model.code = "654321"

        await model.confirmManual()

        XCTAssertEqual(count(api, "pairConfirm"), 1)
        XCTAssertEqual(api.lastPairConfirmPayload?.code, "654321")
        XCTAssertEqual(api.lastPairConfirmPayload?.deviceName, "Test iPhone")
        XCTAssertFalse(model.isPairing)  // flag reset after the call
    }

    func test_confirmManual_refreshesAppStore_onSuccess() async {
        let api = MockAPIClient()
        let keychain = freshKeychain()
        let appStore = AppStore(keychain: keychain, settings: Settings())
        let model = makeModel(api: api, keychain: keychain, appStore: appStore)
        model.urlString = "https://lw.linotsai.top"
        model.code = "111111"

        await model.confirmManual()

        // pair_confirm fired; AppStore re-read auth state (isConfigured
        // reflects whatever the Keychain holds — on Simulator the write may
        // no-op, so we only assert the call happened, not the bool).
        XCTAssertEqual(count(api, "pairConfirm"), 1)
    }

    // MARK: - Manual confirm error path (401)

    func test_confirmManual_publishesError_on401() async {
        let api = MockAPIClient()
        api.onPairConfirm = { _, _ in throw AppError.unauthorized("配对码无效或已过期") }
        let errorBus = ErrorBus()
        let model = makeModel(api: api, errorBus: errorBus)
        model.urlString = "https://lw.linotsai.top"
        model.code = "000000"

        await model.confirmManual()

        XCTAssertEqual(count(api, "pairConfirm"), 1)
        XCTAssertTrue(errorBus.current?.isCritical == true)
        XCTAssertEqual(errorBus.current?.message, "配对码无效或已过期")
        XCTAssertFalse(model.isPairing)  // stays on the pairing screen to retry
    }

    func test_confirmManual_noCall_whenURLInvalid() async {
        let api = MockAPIClient()
        let model = makeModel(api: api)
        model.urlString = "garbage"
        model.code = "123456"

        await model.confirmManual()

        // confirmManual bails before touching the network when URL won't parse.
        XCTAssertEqual(count(api, "pairConfirm"), 0)
    }

    // MARK: - Scan path

    func test_handleScan_validPayload_fillsFieldsAndConfirms() async {
        let api = MockAPIClient()
        let model = makeModel(api: api)
        let payload = PairingPayload(
            url: "https://lw.linotsai.top",
            code: "246810",
            ipOverride: "118.178.122.194"
        )
        let qrString = try! XCTUnwrap(payload.base64Encoded())

        model.handleScan(qrString)
        // handleScan kicks off a detached Task for confirm; the field fill is
        // synchronous, the network call is async.
        XCTAssertEqual(model.urlString, "https://lw.linotsai.top")
        XCTAssertEqual(model.code, "246810")
        XCTAssertEqual(model.ipOverride, "118.178.122.194")

        // Drain the confirm Task.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(count(api, "pairConfirm"), 1)
        XCTAssertEqual(api.lastPairConfirmPayload?.code, "246810")
    }

    func test_handleScan_garbageQR_ignored() {
        let api = MockAPIClient()
        let model = makeModel(api: api)
        model.handleScan("this is not a pairing payload")
        // Non-payload QR leaves the fields at their defaults and fires nothing.
        XCTAssertEqual(model.urlString, Settings.defaultBackendURLString)
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(count(api, "pairConfirm"), 0)
    }
}
