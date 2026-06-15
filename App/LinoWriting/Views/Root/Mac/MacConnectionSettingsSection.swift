#if os(macOS)
import SwiftUI
import AppKit

/// v1.1.0 (FF) Phase 5 — 设置 · 连接 (first section).
///
/// Keeps v1.0.1 single-key auth: backend URL + API_TOKEN(Bearer) → Keychain,
/// every request carries `Authorization: Bearer <token>`. Pixel-exact to the
/// handoff (`LinoWriting.dc.html` CONNECTION block): a white-ish glass card
/// holding 服务器 + status badge, 后端地址 (mono) and 访问密钥·API_TOKEN
/// (mono password), the accent 保存并连接 button, then the "这把密钥访问你自己的
/// 后端" hint line.
///
/// A collapsible macOS DNS / health self-test sits below (折叠默认收起) — kept
/// from v0.8 §5.U.2 because the author still hits WARP / 路由器 DNS 劫持; it is
/// not in the handoff but is a macOS-only diagnostic, not a primary surface.
struct MacConnectionSettingsSection: View {

    let isFirstRun: Bool
    let onDismiss: () -> Void

    @EnvironmentObject private var appStore: AppStore

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    /// `.connected` after a successful save (we have a URL+token pair). Editing
    /// either field drops it back to `.unsaved` so the badge mirrors "你改了，
    /// 还没保存". A live health probe can promote/demote it further.
    @State private var statusState: ConnectionStatus = .unsaved
    @State private var saveError: String?
    @State private var showDiagnostics: Bool = false
    /// Set once `loadExisting` seeds the fields, so the seeding `onChange`
    /// doesn't immediately demote the freshly-loaded 已连接 badge to 未连接.
    @State private var didLoad: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Heading row
            Text("连接后端")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LWColor.titleText)
                .padding(.bottom, 4)
            Text("只需填两样：后端地址 ＋ 访问密钥。没有扫码、没有配对。每台设备配一次即可。")
                .font(.system(size: 12.5))
                .foregroundStyle(LWColor.mutedText3)
                .padding(.bottom, 18)

            card
            hint

            diagnosticsToggle
            if showDiagnostics {
                MacNetworkSelfTest(currentURLString: baseURLString)
                    .padding(.top, 10)
            }

            if isFirstRun {
                Spacer(minLength: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadExisting)
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("服务器")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(LWColor.bodyText)
                Spacer()
                statusBadge
            }
            .padding(.bottom, 16)

            fieldLabel("后端地址")
            monoField(placeholder: "https://your-server.com", text: $baseURLString, secure: false)
                .padding(.bottom, 14)

            fieldLabel("访问密钥 · API_TOKEN（Bearer）")
            monoField(placeholder: "粘贴你的 API_TOKEN", text: $token, secure: true)
                .padding(.bottom, 18)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.danger)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 12) {
                LWPrimaryButton(title: "保存并连接", systemImage: "checkmark", height: 38, enabled: canSave) {
                    save()
                }
                if !isFirstRun {
                    LWBorderedButton(title: "关闭", height: 38) { onDismiss() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.09), lineWidth: 0.5)
        )
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

    private var hint: some View {
        (
            Text("提示：这把密钥用于访问")
            + Text("你自己的后端").foregroundColor(LWColor.hex(0x6B7085)).bold()
            + Text("（写作 / 章节 / 角色数据）。各家大模型的 API Key 在「模型与密钥」里单独配置。")
        )
        .font(.system(size: 12))
        .foregroundStyle(LWColor.mutedText3)
        .lineSpacing(4)
        .padding(.top, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var diagnosticsToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { showDiagnostics.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showDiagnostics ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "stethoscope")
                    .font(.system(size: 11))
                Text("网络自检（DNS / 连接测试）")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(LWColor.mutedText)
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
        .padding(.top, 18)
    }

    // MARK: - Field helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.12 * 11)
            .foregroundStyle(LWColor.mutedText3)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func monoField(placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(LWFont.mono(13))
        .foregroundStyle(LWColor.bodyText)
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(
            LWColor.hex(0xFCFCFE, opacity: 0.8),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
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
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let urlString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.scheme != nil else {
            saveError = "URL 无效，请包含 http(s):// 前缀"
            return
        }
        appStore.saveCredentials(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        saveError = nil
        statusState = .connected
        // First-run path: saving flips `isConfigured`, the shell re-routes off
        // the settings screen automatically. The sheet path stays open so the
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

// MARK: - macOS network self-test (slim glass version)

/// Slim glass restyle of the v0.8 §5.U.2 self-test. Two probes:
///   - 检测 DNS — resolves the host, warns on WARP / 路由器 DNS 劫持 + offers a
///     one-line `/etc/hosts` override to copy.
///   - 测试连接 — hits `<URL>/api/v1/health`; 401 still means "后端通了".
private struct MacNetworkSelfTest: View {

    let currentURLString: String

    @State private var dnsResult: NetworkProbe.DNSResult?
    @State private var healthResult: NetworkProbe.HealthResult?
    @State private var resolving = false
    @State private var probing = false
    @State private var copied = false

    private var parsedHost: String? {
        URL(string: currentURLString.trimmingCharacters(in: .whitespacesAndNewlines))?.host
    }

    private var hostsFixCommand: String {
        let host = parsedHost ?? "lw.linotsai.top"
        let ip = Settings.trustedBackendIPs.first ?? "118.178.122.194"
        return "echo '\(ip)  \(host)' | sudo tee -a /etc/hosts && sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把上面填的 URL 解析到的 IP 和 HZ 实际 IP 对比；如果不一致，本机 DNS 大概率被路由器或 WARP 截胡了。")
                .font(.system(size: 11.5))
                .foregroundStyle(LWColor.mutedText3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                LWBorderedButton(title: "检测 DNS", systemImage: "globe", height: 30) {
                    Task { await runDNS() }
                }
                .disabled(resolving || parsedHost == nil)
                LWBorderedButton(title: "测试连接", systemImage: "bolt.horizontal", height: 30) {
                    Task { await runHealth() }
                }
                .disabled(probing || parsedHost == nil)
            }

            if let dns = dnsResult { dnsBlock(dns) }
            if let h = healthResult { healthBlock(h) }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LWColor.hex(0x787D96, opacity: 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func dnsBlock(_ dns: NetworkProbe.DNSResult) -> some View {
        if let err = dns.resolveError {
            inlineNote(icon: "xmark.octagon.fill", color: LWColor.warning, "无法解析 hostname：\(err)")
        } else if dns.isTrusted {
            inlineNote(icon: "checkmark.circle.fill", color: LWColor.success,
                       "DNS 解析正确  ·  \(dns.addresses.joined(separator: ", "))")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                inlineNote(icon: "exclamationmark.triangle.fill", color: LWColor.danger,
                           "DNS 被劫持：\(parsedHost ?? "hostname") 解析到 \(dns.addresses.joined(separator: ", "))，不是 HZ 的 \(Settings.trustedBackendIPs.joined(separator: ", "))。")
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(hostsFixCommand)
                        .font(LWFont.mono(11))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(LWColor.hex(0x282D46, opacity: 0.06)))
                HStack(spacing: 8) {
                    LWBorderedButton(title: "复制命令", systemImage: "doc.on.doc", height: 28) { copy() }
                    if copied {
                        Text("已复制").font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func healthBlock(_ h: NetworkProbe.HealthResult) -> some View {
        if let err = h.transportError {
            inlineNote(icon: "xmark.octagon.fill", color: LWColor.warning, "连接失败：\(err)  ·  \(h.elapsedMS) ms")
        } else if let code = h.statusCode {
            switch code {
            case 200..<300:
                inlineNote(icon: "checkmark.circle.fill", color: LWColor.success, "HTTP \(code)  ·  \(h.elapsedMS) ms  ·  后端正常")
            case 401:
                inlineNote(icon: "lock.shield", color: LWColor.accentText, "HTTP 401  ·  \(h.elapsedMS) ms  ·  后端通了，token 未通过（token 还没填时是预期）")
            default:
                inlineNote(icon: "exclamationmark.triangle", color: LWColor.warning, "HTTP \(code)  ·  \(h.elapsedMS) ms")
            }
        }
    }

    private func inlineNote(icon: String, color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(LWColor.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runDNS() async {
        guard let host = parsedHost else { return }
        resolving = true
        dnsResult = await NetworkProbe.resolve(host: host)
        resolving = false
    }

    private func runHealth() async {
        guard let url = URL(string: currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        probing = true
        healthResult = await NetworkProbe.probeHealth(baseURL: url)
        probing = false
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hostsFixCommand, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { withAnimation { copied = false } }
        }
    }
}
#endif
