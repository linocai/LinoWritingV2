#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 5 — macOS Liquid Glass settings (four sections).
///
/// Pixel-exact transcription of the handoff 设置 screen
/// (`LinoWriting.dc.html` / `README.md` §4.设置): a top glass segmented
/// control (连接 / 模型与密钥 / 人格编辑 / 调用日志) over a centered (max 768)
/// scroll body.
///
/// Sections:
///   - **连接 (first)** — backend URL + API_TOKEN (Bearer, password) + 保存并连接
///     + 连接状态徽标. Keeps the v1.0.1 single-key auth (URL + token → Keychain,
///     every request carries `Authorization: Bearer <token>`). The mac DNS
///     self-test stays available (折叠在卡片下方).
///   - **模型与密钥** — provider-key cards (label + role badge + model + provider
///     + masked tail + 编辑/删除) + 新增, then 各 Agent 使用的模型 three rows
///     (该角色专属 + 通用 keys as选项, selected高亮). Role mismatch → backend
///     409 → ErrorBus Toast.
///   - **人格编辑** — three persona cards (优化师/Writer/档案员) with role desc +
///     默认/已自定义 badge + system_prompt editor + 恢复默认.
///   - **调用日志** — filter chips (全部/写作/抽取/展开 → writer/extractor/expander)
///     + log cards (agent + chapter + time + preview/error[red] + latency + token).
///
/// The legacy ErrorBus "最近错误" tab is dropped from the top segmentation (作者
/// 拍板砍掉独立 tab); ErrorBus still drives the Toast.
///
/// Used in two places (see `MacShellView` / `RootView`): the ⚙ sheet
/// (`isFirstRun == false`) and the first-run full screen (`isFirstRun == true`,
/// forced to the 连接 section, no 取消).
///
/// macOS-only. iOS keeps the legacy `SettingsView`.
struct MacSettingsView: View {

    let isFirstRun: Bool

    @EnvironmentObject private var appStore: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var section: MacSettingsSection

    init(isFirstRun: Bool = false, initialSection: MacSettingsSection = .connection) {
        self.isFirstRun = isFirstRun
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isFirstRun {
                firstRunHeader
            } else {
                segmentBar
            }
            ScrollView {
                content
                    .frame(maxWidth: 768)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 72)
            }
        }
        .frame(
            minWidth: isFirstRun ? 560 : 720,
            idealWidth: isFirstRun ? 600 : 820,
            minHeight: isFirstRun ? 520 : 560,
            idealHeight: isFirstRun ? 560 : 640
        )
        .background(LWColor.hex(0xFCFCFE, opacity: 0.85))
    }

    // MARK: - Header / segmentation

    /// First-run: no segmentation, locked to 连接 with a friendly title row.
    private var firstRunHeader: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LWColor.logoGradient)
                .frame(width: 34, height: 34)
                .shadow(color: LWColor.hex(0x6A7BFF, opacity: 0.5), radius: 3, y: 2)
                .padding(.top, 26)
            Text("配置连接")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LWColor.titleText)
        }
        .padding(.bottom, 4)
    }

    private var segmentBar: some View {
        HStack {
            Spacer()
            MacSettingsSegmentControl(selection: $section)
            Spacer()
        }
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch isFirstRun ? .connection : section {
        case .connection:
            MacConnectionSettingsSection(isFirstRun: isFirstRun) { dismiss() }
        case .models:
            MacModelsSettingsSection()
        case .persona:
            MacPersonaSettingsSection()
        case .logs:
            MacLogsSettingsSection()
        }
    }
}

// MARK: - Section enum

enum MacSettingsSection: String, CaseIterable, Hashable {
    case connection, models, persona, logs

    var label: String {
        switch self {
        case .connection: return "连接"
        case .models: return "模型与密钥"
        case .persona: return "人格编辑"
        case .logs: return "调用日志"
        }
    }
}

// MARK: - Glass segmented control

/// The handoff segmented control: a `rgba(120,125,150,0.12)` rounded track
/// with the active pill at `#fff` (1px soft shadow) and inactive labels in
/// `#8B90A6`. Pixel-exact to `LinoWriting.dc.html` 设置 顶部分段.
private struct MacSettingsSegmentControl: View {
    @Binding var selection: MacSettingsSection

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MacSettingsSection.allCases, id: \.self) { sec in
                segmentButton(sec)
            }
        }
        .padding(3)
        .background(
            LWColor.hex(0x787D96, opacity: 0.12),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private func segmentButton(_ sec: MacSettingsSection) -> some View {
        let active = selection == sec
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { selection = sec }
        } label: {
            Text(sec.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? LWColor.bodyText : LWColor.mutedText2)
                .frame(height: 32)
                .padding(.horizontal, 18)
                .background(
                    Group {
                        if active {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.white)
                                .shadow(color: LWColor.hex(0x141C3C, opacity: 0.08), radius: 2, y: 1)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }
}
#endif
