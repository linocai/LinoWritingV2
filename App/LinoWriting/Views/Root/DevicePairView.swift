#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

/// v0.9 §5.W.5 (W-3) — the iOS first-launch device-pairing screen.
///
/// Shown full-screen by `RootView` whenever this device has no device
/// token in Keychain (`AppStore.needsDevicePairing`). Two paths, matching
/// §5.W.5:
///
///   A. **Scan (primary)** — point the camera at the QR code macOS shows in
///      its 添加新设备 dialog. The QR encodes `PairingPayload` (base64 JSON,
///      §5.W.2); on a successful decode we auto-run `pair_confirm`.
///   B. **Manual (fallback)** — type BACKEND_URL + the 6-digit code (+ an
///      optional IP override). This is the ONLY path available on the iOS
///      Simulator, which has no camera, so it's first-class.
///
/// Both paths funnel into `DevicePairViewModel.confirm(...)`, which calls
/// the Bearer-less `APIClient.pairConfirm`, persists the returned token to
/// the per-host Keychain row, and tells `AppStore` to re-read auth state so
/// the root view re-routes to the bookshelf.
///
/// The whole file is gated `#if os(iOS)` — AVFoundation camera capture only
/// makes sense on iOS, and macOS is the *pairing source* (it keeps its
/// SettingsView + banner flow from v0.8). `RootView` only references this
/// type from inside its own `#if os(iOS)` branch.
struct DevicePairView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var errorBus: ErrorBus

    @StateObject private var model = DevicePairViewModel()

    /// Tab selection: the camera scanner vs. the manual form. Defaults to
    /// scan; auto-falls back to manual if camera permission is denied.
    @State private var mode: Mode = .scan

    enum Mode: Hashable { case scan, manual }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Picker("配对方式", selection: $mode) {
                    Text("扫码").tag(Mode.scan)
                    Text("手动输入").tag(Mode.manual)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                switch mode {
                case .scan: scanPane
                case .manual: manualPane
                }

                Spacer(minLength: 0)
            }
            .navigationTitle("连接后端")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.isPairing)
            .overlay {
                if model.isPairing {
                    ProgressView("正在配对…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear { model.bind(environment: environment, appStore: appStore, errorBus: errorBus) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text("把这台设备连上写作后端")
                .font(.title3.weight(.semibold))
            Text("在已配好的 macOS 上打开 设置 → 连接 → 设备管理 → 添加新设备，扫描那里的二维码，或手动输入 6 位短码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Scan pane

    @ViewBuilder
    private var scanPane: some View {
        switch model.cameraAuthorization {
        case .authorized:
            CameraScannerView(
                isActive: mode == .scan && !model.isPairing,
                onScan: { scanned in model.handleScan(scanned) }
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
            )
            .padding(.horizontal, 20)
            .overlay(alignment: .bottom) {
                Text("将二维码对准取景框")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

        case .notDetermined:
            VStack(spacing: 14) {
                Image(systemName: "camera")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("需要相机权限才能扫描配对二维码。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("允许使用相机") { Task { await model.requestCameraAccess() } }
                    .buttonStyle(.borderedProminent)
                Button("改用手动输入") { mode = .manual }
                    .buttonStyle(.bordered)
            }
            .padding(28)

        case .denied, .restricted:
            VStack(spacing: 14) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("相机权限已被关闭。前往 设置 开启，或改用下方手动输入短码。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("打开系统设置") { UIApplication.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("改用手动输入") { mode = .manual }
                    .buttonStyle(.bordered)
            }
            .padding(28)

        @unknown default:
            Button("改用手动输入") { mode = .manual }
                .buttonStyle(.bordered)
                .padding(28)
        }
    }

    // MARK: - Manual pane

    private var manualPane: some View {
        Form {
            Section("后端地址") {
                TextField("BACKEND_URL", text: $model.urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
            }
            Section {
                TextField("6 位配对码", text: $model.code)
                    .keyboardType(.numberPad)
                    .font(.system(.title2, design: .monospaced))
                    .onChange(of: model.code) { _, newValue in
                        model.code = DevicePairViewModel.sanitizeCode(newValue)
                    }
            } header: {
                Text("配对码")
            } footer: {
                Text("macOS 添加新设备对话框里显示的 6 位数字，10 分钟内有效。")
            }
            Section {
                TextField("IP override（可选）", text: $model.ipOverride)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("高级")
            } footer: {
                Text("仅当 DNS 被劫持、需要直连 HZ 源站 IP 时填写；通常留空。")
            }
            Section {
                Button {
                    Task { await model.confirmManual() }
                } label: {
                    HStack {
                        Spacer()
                        Text("配对")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitManual)
            }
        }
    }
}

// MARK: - View model

/// Holds the manual-entry state machine + the shared `pair_confirm` →
/// Keychain → refresh sequence for both the scan and manual paths.
///
/// Kept as a separate `ObservableObject` (rather than inline `@State`) so
/// the iOS XCTest bundle can drive the state machine and assert outcomes
/// without standing up a SwiftUI host or a real camera (§5.W.8 / W-3
/// acceptance: "iOS Simulator 走手输短码路径全程跑通").
@MainActor
final class DevicePairViewModel: ObservableObject {
    // Manual-entry fields.
    @Published var urlString: String = Settings.defaultBackendURLString
    @Published var code: String = ""
    @Published var ipOverride: String = ""

    @Published private(set) var isPairing: Bool = false
    @Published var cameraAuthorization: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)

    /// Injected dependencies. Optional so the view model is `init()`-able by
    /// `@StateObject` (which can't pass args); `bind(...)` wires the real
    /// graph on `onAppear`, and tests inject mocks directly.
    private var api: APIClientProtocol?
    private var keychain: KeychainStore?
    private weak var appStore: AppStore?
    private weak var errorBus: ErrorBus?

    /// Used by tests to override the device name (`UIDevice.current.name`
    /// returns the generic "iPhone" on iOS 16+, §5.W.7) without a UIKit
    /// dependency in the test.
    var deviceNameProvider: () -> String = { UIDevice.current.name }

    init() {}

    /// Test seam: inject the full dependency set without `bind(environment:)`.
    init(
        api: APIClientProtocol,
        keychain: KeychainStore,
        appStore: AppStore? = nil,
        errorBus: ErrorBus? = nil,
        cameraAuthorization: AVAuthorizationStatus = .authorized
    ) {
        self.api = api
        self.keychain = keychain
        self.appStore = appStore
        self.errorBus = errorBus
        self.cameraAuthorization = cameraAuthorization
    }

    func bind(environment: AppEnvironment, appStore: AppStore, errorBus: ErrorBus) {
        // Don't clobber a test-injected graph.
        guard api == nil else { return }
        self.api = environment.apiClient
        self.keychain = environment.keychain
        self.appStore = appStore
        self.errorBus = errorBus
    }

    // MARK: Manual-entry validation

    /// Strips non-digits and clamps to 6 chars — wired to the numberPad
    /// field's `onChange` so paste / autofill can't sneak in junk.
    static func sanitizeCode(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(6))
    }

    /// `true` when the manual form is submittable: a parseable URL and an
    /// exactly-6-digit code. The IP override is optional and unvalidated
    /// here (the backend / network layer is the source of truth on reach).
    var canSubmitManual: Bool {
        guard !isPairing else { return false }
        guard parsedURL != nil else { return false }
        return code.count == 6 && code.allSatisfy(\.isNumber)
    }

    private var parsedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme, !scheme.isEmpty,
              url.host != nil
        else { return nil }
        return url
    }

    // MARK: Scan path

    /// Called by the camera representable on every detected QR string. We
    /// decode it as a `PairingPayload`; a non-payload QR (some other code in
    /// frame) is silently ignored so the scanner keeps running. A successful
    /// decode fills the manual fields (so the user can see what was scanned /
    /// fall back to manual if confirm fails) and auto-confirms.
    func handleScan(_ scanned: String) {
        guard !isPairing else { return }
        guard let payload = PairingPayload.fromBase64(scanned) else { return }
        urlString = payload.url
        code = payload.code
        ipOverride = payload.ipOverride ?? ""
        Task { await confirm(url: payload.url, code: payload.code, ipOverride: payload.ipOverride) }
    }

    // MARK: Manual path

    func confirmManual() async {
        guard let url = parsedURL else { return }
        let trimmedIP = ipOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        await confirm(url: url.absoluteString, code: code, ipOverride: trimmedIP.isEmpty ? nil : trimmedIP)
    }

    // MARK: Shared confirm

    /// The single funnel both paths share. Persists the backend URL to
    /// Keychain FIRST (so `APIClient.baseURLProvider` can reach the Bearer-
    /// less `pair_confirm` endpoint), runs the confirm, stores the returned
    /// token to the per-host Keychain row, and refreshes `AppStore`.
    ///
    /// `ipOverride` is captured but not persisted: the app has no runtime
    /// IP-override mechanism (the DNS self-check reads the compile-time
    /// `Settings.trustedBackendIPs`), so the QR's `ip` is informational
    /// only at this stage. Recorded here so a future runtime-override
    /// feature has the value at hand; intentionally not invented now (W-3
    /// must not add persistence infrastructure).
    func confirm(url: String, code: String, ipOverride: String?) async {
        guard !isPairing else { return }
        guard let api, let keychain else { return }
        guard let baseURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorBus?.publish(.validation("后端地址无效"))
            return
        }
        let trimmedCode = Self.sanitizeCode(code)
        guard trimmedCode.count == 6 else {
            errorBus?.publish(.validation("配对码必须是 6 位数字"))
            return
        }

        isPairing = true
        defer { isPairing = false }

        // Stash the URL so the pre-auth endpoint is reachable. We do NOT
        // touch any other host's token row; the per-host token write below
        // lands on this URL's host.
        keychain.baseURL = baseURL
        _ = ipOverride  // captured-not-persisted; see doc comment above.

        do {
            let resp = try await api.pairConfirm(code: trimmedCode, deviceName: deviceNameProvider())
            keychain.token = resp.token
            appStore?.refreshAuthState()
        } catch let error as AppError {
            errorBus?.publish(error)
        } catch {
            errorBus?.publish(.transport(error.localizedDescription))
        }
    }

    // MARK: Camera permission

    /// Requests camera access (first-launch prompt) and updates
    /// `cameraAuthorization` so the scan pane re-renders.
    func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAuthorization = granted ? .authorized : .denied
    }
}

// MARK: - Camera scanner (UIViewControllerRepresentable)

/// Wraps an `AVCaptureSession` + `AVCaptureMetadataOutput` configured for
/// QR detection inside a `UIViewControllerRepresentable`. The preview layer
/// fills the controller's view; detected metadata strings are forwarded to
/// `onScan`.
///
/// `isActive` lets the parent pause capture (e.g. while a pair_confirm is in
/// flight or the manual tab is selected) without tearing down the session.
/// The session itself is started / stopped on a background queue per Apple's
/// guidance (`startRunning` blocks).
struct CameraScannerView: UIViewControllerRepresentable {
    let isActive: Bool
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        vc.setActive(isActive)
    }

    /// Bridges `AVCaptureMetadataOutputObjectsDelegate` callbacks to the
    /// SwiftUI `onScan` closure, de-duping rapid repeat reads of the same
    /// code so we don't fire `pair_confirm` dozens of times.
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: (String) -> Void
        private var lastValue: String?

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let value = obj.stringValue,
                  value != lastValue
            else { return }
            lastValue = value
            onScan(value)
        }
    }
}

/// Hosts the capture session + preview layer. Kept as a plain UIKit VC
/// (rather than building the session in the representable) so the preview
/// layer's frame tracks `viewDidLayoutSubviews` correctly across rotation.
final class ScannerViewController: UIViewController {
    weak var coordinator: CameraScannerView.Coordinator?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.lino.linowriting.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }   // No camera (Simulator) — view stays black; user uses manual tab.
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        // Set AFTER adding the output, otherwise `.qr` isn't yet in
        // `availableMetadataObjectTypes` and this throws.
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
        isConfigured = true
    }

    func setActive(_ active: Bool) {
        guard isConfigured else { return }
        sessionQueue.async { [session] in
            if active {
                if !session.isRunning { session.startRunning() }
            } else {
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setActive(false)
    }
}
#endif
