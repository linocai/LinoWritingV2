#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — the iPhone Liquid Glass settings sheet (four grouped
/// sections).
///
/// Replaces the legacy `SettingsView` iOS body (a `Form` of NavigationLinks)
/// behind the `appStore.showSettings` sheet, presented from the shelf ⚙ button.
/// Pixel-aligned to the handoff 设置 sheet (`LinoWriting iOS.dc.html`
/// L359–447): a grabber + 设置 / 完成 header over an `#F2F2F7` grouped grid that
/// scrolls all sections in one column (NOT a top segmented control — the iOS
/// design lists 连接 → 模型与密钥 → 人格编辑 vertically):
///
///   - **连接** — backend URL + API_TOKEN(Bearer) + 保存并连接 + status badge.
///     Keeps v1.0.1 single-key auth (URL + token → Keychain, every request
///     carries `Authorization: Bearer <token>`).
///   - **模型与密钥** — provider-key cards + 新增 (reuses `ProviderKeyEditSheet`)
///     + per-agent active key chips (409 role-mismatch → Toast).
///   - **人格编辑** — three persona cards (默认/已自定义 badge + editor + 恢复默认).
///
/// The legacy ErrorBus「最近错误」tab is dropped (同 macOS Phase 5, 作者拍板砍掉
/// 独立 tab); ErrorBus still drives the Toast. **调用日志 dropped on iOS in
/// v1.2.0 (HH) P3** (作者拍板瘦身) — macOS keeps it (`MacLogsSettingsSection`),
/// the backend log endpoints are unchanged.
///
/// Presented as `.sheet` with `.presentationDetents([.large])` — the
/// presentation chrome (drag indicator) is configured in `RootView`. iOS-only;
/// macOS routes through `MacSettingsView`.
struct IOSSettingsView: View {

    @EnvironmentObject private var appStore: AppStore

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    IOSConnectionSettingsSection()
                    IOSModelsSettingsSection()
                    IOSPersonaSettingsSection()
                    // v1.2.0 (HH) P3: 调用日志 section dropped on iOS (作者拍板瘦身).
                    // The backend log endpoints stay — macOS still reads them.
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(LWColor.hex(0xF2F2F7).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(LWColor.titleText)
            Spacer()
            Button { appStore.showSettings = false } label: {
                Text("完成")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LWColor.accentText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

/// v1.2.0 (GG, P6) — first-run connection shell.
///
/// The `!isConfigured` gate in `RootViewIOS` lands here instead of the legacy
/// `SettingsView(isFirstRun: true)`. It reuses the same `IOSConnectionSettings
/// Section` card as the settings sheet so onboarding looks identical to the 连接
/// section. Saving flips `appStore.isConfigured`, and the shell re-routes off
/// this screen into the bookshelf automatically (no 取消 / 完成 — there's nothing
/// to dismiss to yet).
struct IOSFirstRunConnectionView: View {
    var body: some View {
        VStack(spacing: 0) {
            firstRunHeader
            ScrollView {
                IOSConnectionSettingsSection()
                    .padding(.top, 4)
                    .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(LWColor.hex(0xF2F2F7).ignoresSafeArea())
    }

    private var firstRunHeader: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LWColor.logoGradient)
                .frame(width: 38, height: 38)
                .shadow(color: LWColor.hex(0x6A7BFF, opacity: 0.5), radius: 4, y: 2)
            Text("配置连接")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(LWColor.titleText)
            Text("填入后端地址与访问密钥，即可开始写作。")
                .font(.system(size: 13))
                .foregroundStyle(LWColor.mutedText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }
}
#endif
