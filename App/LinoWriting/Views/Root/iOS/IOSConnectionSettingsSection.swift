#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — 设置 · 连接 (first grouped section + first-run shell).
///
/// Keeps the v1.0.1 single-key auth: backend URL + API_TOKEN(Bearer) → Keychain,
/// every request carries `Authorization: Bearer <token>`. There is no pairing,
/// no per-device key — one fixed shared token accesses the author's own
/// backend.
///
/// Pixel-aligned to the handoff CONNECTION block (`LinoWriting iOS.dc.html`
/// L370–387): a white rounded grouped card holding 服务器 + status badge,
/// 后端地址 (mono input) and 访问密钥·API_TOKEN（Bearer）(mono password input),
/// the accent 保存并连接 button, then the "这把密钥访问你自己的后端" hint line.
///
/// Used in two shapes:
///   - inside `IOSSettingsView` (`.sheet`), where the card sits on the `#F2F2F7`
///     grouped grid (no own background here).
///   - as the first-run shell (`IOSFirstRunConnectionView`), reusing this same
///     card so onboarding looks identical to the settings 连接 section.
struct IOSConnectionSettingsSection: View {

    @EnvironmentObject private var appStore: AppStore

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    /// `.connected` once we have a saved URL+token pair. Editing either field
    /// drops it back to `.unsaved` so the badge mirrors "你改了，还没保存".
    @State private var statusState: ConnectionStatus = .unsaved
    @State private var saveError: String?
    /// Set once `loadExisting` seeds the fields, so the seeding `onChange`
    /// doesn't immediately demote the freshly-loaded 已连接 badge to 未连接.
    @State private var didLoad: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("连接后端 · 只需填两样")
            card
                .padding(.horizontal, 16)
            saveButton
            hint
        }
        .onAppear(perform: loadExisting)
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            // 服务器 + status badge
            HStack {
                Text("服务器")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LWColor.titleText)
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            divider

            // 后端地址
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("后端地址")
                monoField(placeholder: Settings.defaultBackendURLString, text: $baseURLString, secure: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            divider

            // 访问密钥 · API_TOKEN
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("访问密钥 · API_TOKEN（Bearer）")
                monoField(placeholder: "粘贴你的 API_TOKEN", text: $token, secure: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusState.dotColor)
                .frame(width: 7, height: 7)
            Text(statusState.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusState.fgColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(statusState.bgColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("保存并连接")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(LWColor.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: LWColor.accentStop.opacity(0.5), radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .opacity(canSave ? 1 : 0.5)
        .disabled(!canSave)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var hint: some View {
        Text("这把密钥访问你自己的后端；各家大模型 API Key 在下方单独配置。")
            .font(.system(size: 12))
            .foregroundStyle(LWColor.mutedText3)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .padding(.bottom, 7)
    }

    private var divider: some View {
        Rectangle()
            .fill(LWColor.hex(0x3C3C43, opacity: 0.1))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LWColor.mutedText3)
    }

    @ViewBuilder
    private func monoField(placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .textFieldStyle(.plain)
        .font(LWFont.mono(13))
        .foregroundStyle(LWColor.bodyText)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(LWColor.hex(0xFBFBFD), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5)
        )
        .onChange(of: text.wrappedValue) { _, _ in
            // Skip the seeding change from `loadExisting`; only real author
            // edits should demote the badge.
            guard didLoad else { return }
            if statusState == .connected { statusState = .unsaved }
            saveError = nil
        }
    }

    // MARK: - State

    private var canSave: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadExisting() {
        baseURLString = KeychainStore.shared.baseURL?.absoluteString ?? ""
        token = KeychainStore.shared.token ?? ""
        statusState = KeychainStore.shared.isConfigured ? .connected : .unsaved
        // Defer enabling demote-on-edit until after this seeding settles, so
        // the onChange fired by the assignments above doesn't undo .connected.
        DispatchQueue.main.async { didLoad = true }
    }

    private func save() {
        let urlString = baseURLString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), url.scheme != nil else {
            saveError = "URL 无效，请包含 http(s):// 前缀"
            return
        }
        appStore.saveCredentials(baseURL: url, token: token.trimmingCharacters(in: .whitespaces))
        saveError = nil
        statusState = .connected
        // First-run path: saving flips `isConfigured`, the shell re-routes off
        // the connection screen automatically. The sheet path stays open so the
        // author can keep tweaking other sections.
    }

    // MARK: - Status enum

    enum ConnectionStatus {
        /// Have a saved URL+token pair in Keychain.
        case connected
        /// No saved pair / fields edited since last save.
        case unsaved

        var label: String {
            switch self {
            case .connected: return "已连接"
            case .unsaved: return "未连接"
            }
        }
        var dotColor: Color {
            switch self {
            case .connected: return LWColor.hex(0x34C759)
            case .unsaved: return LWColor.danger
            }
        }
        var fgColor: Color {
            switch self {
            case .connected: return LWColor.success
            case .unsaved: return LWColor.danger
            }
        }
        var bgColor: Color {
            switch self {
            case .connected: return LWColor.success.opacity(0.1)
            case .unsaved: return LWColor.danger.opacity(0.1)
            }
        }
    }
}
#endif
