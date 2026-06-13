import SwiftUI
#if os(macOS)
import AppKit
#endif

/// App settings.
///
/// Per PROJECT_PLAN §5.E.6 the v0.6 settings surface is split into two tabs:
///   - **Connection** — backend base URL + API token (i.e. the v0.5 form)
///   - **LLM Providers** — multi-key management (list / add / edit / delete /
///     set-active)
///
/// v0.7 §5.N adds a third tab "最近错误" listing `ErrorBus.history` so the
/// author can re-read messages that auto-dismissed from the Toast.
///
/// First-run mode (`isFirstRun = true`) hides the LLM + error tabs because
/// the user can't even reach the backend yet without first saving
/// credentials, and there's no error history worth showing pre-connect.
public struct SettingsView: View {

    @EnvironmentObject var appStore: AppStore
    @Environment(\.dismiss) private var dismiss

    public var isFirstRun: Bool

    /// Tab selector. First-run mode forces `.connection`.
    /// v0.7 §5.D / Phase D-log adds `.agentLogs` for the Admin Log Panel.
    private enum Tab: Hashable { case connection, providers, personas, errorLog, agentLogs }
    @State private var tab: Tab = .connection

    public init(isFirstRun: Bool = false) {
        self.isFirstRun = isFirstRun
    }

    public var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    /// macOS body: the v0.7 segmented-Picker + four-pane tabs at fixed
    /// 560×540. Unchanged from v0.7 — R-3 only adds the iOS branch.
    @ViewBuilder
    private var macOSBody: some View {
        Group {
            if isFirstRun {
                // First-run: skip the tab chrome entirely. The user hasn't
                // connected to a backend yet, so the LLM tab can't do anything.
                ConnectionSettingsView(isFirstRun: true)
                    .frame(width: 480)
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("连接").tag(Tab.connection)
                        Text("LLM Providers").tag(Tab.providers)
                        Text("人格").tag(Tab.personas)
                        Text("最近错误").tag(Tab.errorLog)
                        Text("Agent 日志").tag(Tab.agentLogs)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                    Divider()

                    Group {
                        switch tab {
                        case .connection:
                            ConnectionSettingsView(isFirstRun: false)
                        case .providers:
                            ProviderKeysSettingsView()
                        case .personas:
                            PersonaSettingsView()
                        case .errorLog:
                            ErrorLogSettingsView()
                        case .agentLogs:
                            AgentLogSettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 560, height: 540)
            }
        }
    }
    #endif

    #if os(iOS)
    /// v0.8 §5.R.5 — iOS settings adopt the native Settings.app vibe:
    /// `NavigationStack` + `Form` with each tab as a row that pushes
    /// onto a detail screen. First-run still skips the chrome and
    /// presents the connection form directly so the user can finish
    /// onboarding without a stop in a menu.
    @ViewBuilder
    private var iOSBody: some View {
        if isFirstRun {
            NavigationStack {
                ConnectionSettingsView(isFirstRun: true)
                    .navigationTitle("配置连接")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            NavigationStack {
                Form {
                    Section("后端") {
                        NavigationLink {
                            ConnectionSettingsView(isFirstRun: false)
                                .navigationTitle("连接")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("连接", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    Section("模型") {
                        NavigationLink {
                            ProviderKeysSettingsView()
                                .navigationTitle("LLM Providers")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("LLM Providers", systemImage: "key")
                        }
                        NavigationLink {
                            PersonaSettingsView()
                                .navigationTitle("Agent 人格")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("Agent 人格", systemImage: "person.text.rectangle")
                        }
                    }
                    Section("诊断") {
                        NavigationLink {
                            ErrorLogSettingsView()
                                .navigationTitle("最近错误")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("最近错误", systemImage: "exclamationmark.triangle")
                        }
                        NavigationLink {
                            AgentLogSettingsView()
                                .navigationTitle("Agent 日志")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("Agent 日志", systemImage: "scroll")
                        }
                    }
                }
                .navigationTitle("设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }
    #endif
}

// MARK: - Connection tab

/// The v0.5 backend URL + token form, lifted into a sub-view so the new
/// tabbed settings shell can compose it.
private struct ConnectionSettingsView: View {

    @EnvironmentObject var appStore: AppStore
    @Environment(\.dismiss) private var dismiss

    let isFirstRun: Bool

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if appStore.pendingTokenSetupBanner && !isFirstRun {
                    TokenSetupBanner()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("配置后端连接")
                        .font(.title2.weight(.semibold))
                    Text("请填入后端服务地址与访问 Token。两项都保存在本机 Keychain。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    fieldRow(
                        label: "API Base URL",
                        placeholder: Settings.defaultBackendURLString,
                        text: $baseURLString
                    )
                    fieldRow(
                        label: "API Token",
                        placeholder: "•••••••••",
                        text: $token,
                        secure: true
                    )
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    #if os(macOS)
                    if !isFirstRun {
                        Button("取消") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    #endif
                    Spacer()
                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        #if os(macOS)
                        .keyboardShortcut(.defaultAction)
                        #endif
                        .disabled(!canSave)
                }

                #if os(macOS)
                // v0.8 §5.U.2 macOS-only network self-test. iOS users
                // typically can't edit /etc/hosts and don't share the
                // author's WARP / router DNS hijack scenario, so the
                // section is hidden on iOS.
                NetworkSelfTestSection(currentURLString: baseURLString)
                    .padding(.top, 8)

                // v0.9 §5.W.5 macOS-only 设备管理: list paired devices +
                // "添加新设备" QR/short-code dialog. Hidden on iOS because
                // an iPhone isn't a pairing *source* (§5.W.5 simplifies the
                // iOS UX to "this device only"); iOS device management lands
                // in a later phase.
                if !isFirstRun {
                    DeviceManagementSection(currentURLString: baseURLString)
                        .padding(.top, 8)
                }
                #endif
            }
            .padding(28)
        }
        .onAppear(perform: loadExisting)
    }

    private var canSave: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadExisting() {
        baseURLString = KeychainStore.shared.baseURL?.absoluteString ?? ""
        token = KeychainStore.shared.token ?? ""
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium))
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let urlString = baseURLString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), url.scheme != nil else {
            error = "URL 无效，请包含 http(s):// 前缀"
            return
        }
        appStore.saveCredentials(baseURL: url, token: token.trimmingCharacters(in: .whitespaces))
        error = nil
        if !isFirstRun { dismiss() }
    }
}

// MARK: - LLM Providers tab

private struct ProviderKeysSettingsView: View {

    @EnvironmentObject private var store: ProviderKeysStore
    @State private var editingKey: ProviderKey?
    @State private var showCreateSheet: Bool = false
    @State private var pendingDelete: ProviderKey?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.load() }
        .sheet(isPresented: $showCreateSheet) {
            ProviderKeyEditSheet(existing: nil)
        }
        .sheet(item: $editingKey) { key in
            ProviderKeyEditSheet(existing: key)
        }
        .alert("删除 LLM Key", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let key = pendingDelete {
                    Task { await store.delete(id: key.id) }
                }
                pendingDelete = nil
            }
        } message: {
            if let key = pendingDelete {
                Text("将删除「\(key.keyLabel)」。如果它当前是 active key，删除后 LLM 调用会失败，请先选择其它 key。")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Providers")
                    .font(.title3.weight(.semibold))
                Text("管理 OpenAI-compatible Key（xAI / OpenAI / OpenRouter / DeepSeek / 自部署）。当前 active key 决定所有写作请求走哪条 endpoint。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showCreateSheet = true
            } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("还没有任何 LLM Key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点击右上「添加」录入一组 OpenAI-compatible endpoint。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PerAgentActiveSection()
                        .padding(.horizontal, 4)

                    Divider()
                        .padding(.horizontal, 4)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的 keys")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        LazyVStack(spacing: 8) {
                            ForEach(store.sortedItems) { key in
                                ProviderKeyRow(
                                    key: key,
                                    isActive: store.active?.activeProviderKeyId == key.id,
                                    onSetActive: { Task { await store.setActive(id: key.id) } },
                                    onEdit: { editingKey = key },
                                    onDelete: { pendingDelete = key }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Per-Agent active picker (§5.M / M-2)

/// "按 Agent 分别选择" 区:每个 Agent 一个 picker,默认"沿用通用 active"。
/// 选了不兼容(key.agent_role 非 nil 且与 slot 不匹配)的 key,后端返 409,
/// ErrorBus toast 提示;UI 上对不兼容 key 灰显并加 "非 {role} 专用" 后缀,
/// 让用户先看到不兼容信号而非纯靠 409 弹错。
private struct PerAgentActiveSection: View {

    @EnvironmentObject private var store: ProviderKeysStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按 Agent 分别选择(可选)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("不选 = 沿用上方通用 active key。Writer 走顶级模型(贵)、Extractor 用中端足够、Expander 任意便宜模型即可,可显著控成本。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(AgentRole.allCases, id: \.self) { role in
                    PerAgentRow(role: role)
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct PerAgentRow: View {

    @EnvironmentObject private var store: ProviderKeysStore
    let role: AgentRole

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(role.displayName)
                .font(.callout.weight(.medium))
                .frame(width: 84, alignment: .leading)

            // M-2 reviewer 🟡 #1: try `.foregroundStyle(.secondary)` on the
            // option Text when the key is bound to a different agent_role
            // (incompatible). SwiftUI Picker(.menu) is known to ignore
            // most styling on menu items, so this may render identically
            // to the regular options on macOS — the "· 非 X 专用" suffix
            // remains the authoritative cue. We still apply the style for
            // platforms / future SwiftUI versions that honour it; the
            // 409 from the backend is the last-line defence.
            Picker("", selection: selectionBinding) {
                Text("沿用通用 active").tag(Optional<String>.none)
                ForEach(store.sortedItems) { key in
                    Text(label(for: key))
                        .foregroundStyle(isIncompatible(key) ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        .tag(Optional(key.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(store.isMutating)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.04))
        )
    }

    /// 当前 slot 选择的 provider_key_id;nil 表示"沿用通用 active"。
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.activeAgents[role]?.activeProviderKeyId },
            set: { newId in
                Task { await store.setActiveAgentKey(agentRole: role, providerKeyId: newId) }
            }
        )
    }

    /// 显示:label + (model_name) [+ "·非 {role} 专用"](不兼容时)。
    private func label(for key: ProviderKey) -> String {
        let base = "\(key.keyLabel) · \(key.modelName)"
        if isIncompatible(key) {
            return "\(base)  ·  非 \(role.displayName) 专用"
        }
        return base
    }

    /// Key is incompatible with this slot when it's pinned to a different agent_role.
    /// generic (agent_role == nil) keys are compatible with every slot.
    private func isIncompatible(_ key: ProviderKey) -> Bool {
        if let r = key.agentRole, r != role { return true }
        return false
    }
}

// MARK: - Row

private struct ProviderKeyRow: View {
    let key: ProviderKey
    let isActive: Bool
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Active radio
            Button(action: onSetActive) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "当前 active" : "设为 active")

            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.keyLabel)
                        .font(.callout.weight(.medium))
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if let role = key.agentRole {
                        Text("\(role.displayName) 专用")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.purple)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("编辑", action: onEdit)
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("删除")
            }
            .opacity(isHovered ? 1.0 : 0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.06) : Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .onHover { isHovered = $0 }
    }

    private var iconName: String {
        switch key.providerHint {
        case "xai": return "bolt.fill"
        case "openai": return "sparkles"
        case "openrouter": return "arrow.triangle.branch"
        case "deepseek": return "magnifyingglass"
        default: return "brain"
        }
    }

    private var subtitle: String {
        let hint = key.providerHint?.isEmpty == false ? key.providerHint! : "custom"
        return "\(hint) · \(key.modelName) · \(key.apiKey)"
    }
}

// MARK: - 最近错误 tab (v0.7 §5.N)

/// Lists `ErrorBus.history` newest-first so the user can re-read errors
/// that the bottom-trailing Toast auto-dismissed.
///
/// Design notes:
/// - The Toast (3s auto-dismiss for non-critical, sticky for 401) stays
///   unchanged — this tab is purely "回看消失了的消息".
/// - We deliberately render even already-dismissed notices: ``dismiss()``
///   only clears ``current``, never ``history``. The 清空 button is the
///   one and only way to wipe the log.
/// - No "重试" button here yet — that's a later phase if v0.7 wants it;
///   N's scope is "能回看" only (plan §5.N.2).
private struct ErrorLogSettingsView: View {

    @EnvironmentObject private var bus: ErrorBus

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近错误")
                    .font(.title3.weight(.semibold))
                Text("Toast 已经消失的错误也能在这里回看。最多保留最近 \(ErrorBus.historyLimit) 条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                bus.clearHistory()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(bus.history.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if bus.history.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("还没有错误记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Newest first — `history` is appended on each publish,
                    // so reversed() gives the natural "most recent at top"
                    // ordering an author expects when scanning a log.
                    ForEach(bus.history.reversed()) { notice in
                        ErrorLogRow(notice: notice)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct ErrorLogRow: View {
    let notice: ErrorBus.Notice

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isCritical ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.isCritical ? Color.red : Color.orange)
                .font(.body)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(Self.timeFormatter.string(from: notice.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    notice.isCritical ? Color.red.opacity(0.25) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Agent 日志 tab (v0.7 §5.D / Phase D-log)

/// Lists `agent_logs` rows from the backend so the author can audit each
/// LLM call (input prompt / output preview / latency / status). Replaces
/// the v0.5 promise that "APIClient already exposes listAgentLogs, UI is
/// the only thing missing".
///
/// Design notes:
/// - Mirrors the visual rhythm of `ErrorLogSettingsView` (header + content
///   columns, monospaced time, RoundedRectangle row chrome) so the four
///   tabs feel like one consistent surface.
/// - Rows are folded by default. Tapping reveals `inputPreview` and
///   `outputPreview` in monospaced scrollable boxes. Previews are already
///   length-capped + sensitive-data-scrubbed on the backend
///   (`openai_compatible.py`'s 4xx scrub from §5.P.1), so we render them
///   verbatim.
/// - Infinite scroll: LazyVStack's `onAppear` on the last row triggers
///   `loadMore`. Once `hasMore == false` we drop the spinner.
private struct AgentLogSettingsView: View {

    @EnvironmentObject private var store: AgentLogStore

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            // Only do an initial load when entries is empty so re-opening
            // the Settings sheet doesn't blow away the user's scroll state.
            if store.entries.isEmpty {
                await store.load()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 日志")
                    .font(.title3.weight(.semibold))
                Text("回看每次 Expander / Writer / Extractor / 强制重置 调用的 prompt、输出与耗时。点击任一行展开看完整 input/output。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await store.load() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            if store.isLoading && store.entries.isEmpty {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "scroll")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有 Agent 调用记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("展开提纲 / 写作 / 提取 后这里会出现条目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            AgentLogRow(entry: entry)
                                .onAppear {
                                    // Trigger pagination when the very last
                                    // row enters the viewport. Guards inside
                                    // loadMore() already filter dup calls.
                                    if index == store.entries.count - 1 {
                                        Task { await store.loadMore() }
                                    }
                                }
                        }
                        if store.isLoading && !store.entries.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        } else if !store.hasMore {
                            Text("— 已是最早的记录 —")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("过滤", selection: filterBinding) {
                ForEach(AgentLogStore.AgentLogFilter.allCases, id: \.self) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()
        }
    }

    private var filterBinding: Binding<AgentLogStore.AgentLogFilter> {
        Binding(
            get: { store.filter },
            set: { newValue in
                Task { await store.setFilter(newValue) }
            }
        )
    }
}

/// A single `agent_logs` row. Collapsed by default; tap to expand and
/// reveal the prompt + response previews.
private struct AgentLogRow: View {

    let entry: AgentLog

    @State private var isExpanded: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if isExpanded {
                expandedBody
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    statusColor.opacity(isError ? 0.25 : 0.08),
                    lineWidth: 1
                )
        )
    }

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.body)
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agentDisplayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(Self.dateFormatter.string(from: entry.createdAt) + " " + Self.timeFormatter.string(from: entry.createdAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(isError ? "失败" : "成功")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor)
                        if let ms = entry.latencyMs {
                            Text("\(ms) ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let inTok = entry.tokensIn, let outTok = entry.tokensOut {
                            Text("↑\(inTok) ↓\(outTok)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.bottom, 2)

            if let err = entry.error, !err.isEmpty {
                previewBlock(title: "错误", text: err, tint: .red)
            }

            if let input = entry.inputPreview, !input.isEmpty {
                previewBlock(title: "Input", text: input, tint: .secondary)
            } else {
                emptyBlock(title: "Input")
            }

            if let output = entry.outputPreview, !output.isEmpty {
                previewBlock(title: "Output", text: output, tint: .secondary)
            } else {
                emptyBlock(title: "Output")
            }
        }
    }

    private func previewBlock(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func emptyBlock(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("(空)")
                .font(.caption.italic())
                .foregroundStyle(.tertiary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }

    private var isError: Bool {
        // Backend writes `error` only on failure paths; presence ⇒ failure.
        if let e = entry.error, !e.isEmpty { return true }
        return false
    }

    private var statusColor: Color {
        isError ? Color.red : Color.green
    }

    private var statusIcon: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    /// Map backend `agent_name` to a friendly Chinese label. Keep this
    /// in lock-step with `AgentLogStore.AgentLogFilter.displayName` so
    /// the filter Picker label and the row label match (e.g. selecting
    /// "提取" must surface rows whose label says "提取").
    private var agentDisplayName: String {
        switch entry.agentName {
        case "expander": return "提纲展开"
        case "writer": return "写作"
        case "extractor": return "提取"
        case "admin_reset": return "强制重置"
        default: return entry.agentName
        }
    }
}

// MARK: - v0.8 §5.U.2 Token-setup banner

/// Red banner at the top of the Connection tab. Displayed when
/// `AppStore.pendingTokenSetupBanner == true`, i.e. the current `baseURL`'s
/// host has no token in Keychain yet. Disappears the moment the author
/// fills in the field and hits 保存 (`AppStore.saveCredentials` flips the
/// flag back to `false`).
private struct TokenSetupBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
                .font(.body)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("请填入云后端 API token")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("LinoI 默认连接 \(Settings.defaultBackendURLString)。该后端在本机 Keychain 还没有对应 token，所有请求会因 401 被拒。请在下方填好 token 并保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
    }
}

#if os(macOS)
// MARK: - v0.8 §5.U.2 Network self-test (macOS only)

/// "网络自检" sub-section inside the Connection tab. Two buttons:
///
///   - **检测 DNS** — resolves the hostname inside `currentURLString` via
///     `NetworkProbe.resolve(host:)`. Surfaces a red WARP-hijack warning
///     plus a one-click copy of the `/etc/hosts` override command when
///     the resolved IP isn't in `Settings.trustedBackendIPs`.
///
///   - **测试连接** — hits `<URL>/api/v1/health` via
///     `NetworkProbe.probeHealth(baseURL:)`. Mostly a sanity check that
///     TLS + the reverse proxy are alive; `401` from the auth middleware
///     is still considered "backend up".
///
/// iOS hides this whole section because:
///   1. iOS real devices don't ship `/etc/hosts` and `sudo` is meaningless
///   2. Cellular / corporate Wi-Fi don't usually carry the home-router
///      hijack signature the author runs into on macOS.
private struct NetworkSelfTestSection: View {

    let currentURLString: String

    @State private var dnsResult: NetworkProbe.DNSResult?
    @State private var healthResult: NetworkProbe.HealthResult?
    @State private var isResolvingDNS: Bool = false
    @State private var isProbingHealth: Bool = false
    @State private var copyConfirmation: String?

    /// The exact one-liner the author should run in Terminal to override
    /// DNS for the production hostname. Adds an `/etc/hosts` row, flushes
    /// the DirectoryService cache, then HUPs `mDNSResponder` so the new
    /// row takes effect immediately rather than after the next reboot.
    private var hostsFixCommand: String {
        let host = parsedHost ?? "lw.linotsai.top"
        let ip = Settings.trustedBackendIPs.first ?? "118.178.122.194"
        return "echo '\(ip)  \(host)' | sudo tee -a /etc/hosts && sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    }

    private var parsedHost: String? {
        URL(string: currentURLString.trimmingCharacters(in: .whitespaces))?.host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                Text("网络自检")
                    .font(.callout.weight(.semibold))
            }
            Text("把上面填的 URL 解析到的 IP 和 HZ 实际 IP 对比；如果不一致，本机的 DNS 大概率被路由器或 WARP 截胡了。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await runDNS() }
                } label: {
                    if isResolvingDNS {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检测 DNS", systemImage: "globe")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isResolvingDNS || parsedHost == nil)

                Button {
                    Task { await runHealth() }
                } label: {
                    if isProbingHealth {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isProbingHealth || parsedHost == nil)
            }

            if let dns = dnsResult {
                dnsResultBlock(dns)
            }
            if let h = healthResult {
                healthResultBlock(h)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func dnsResultBlock(_ dns: NetworkProbe.DNSResult) -> some View {
        if let err = dns.resolveError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
                Text("无法解析 hostname：\(err)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if dns.isTrusted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("DNS 解析正确  ·  \(dns.addresses.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        } else {
            hijackWarning(resolvedAddresses: dns.addresses)
        }
    }

    @ViewBuilder
    private func hijackWarning(resolvedAddresses: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DNS 被劫持")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("\(parsedHost ?? "hostname") 被本机解析到 \(resolvedAddresses.joined(separator: ", "))，不是 HZ 的 \(Settings.trustedBackendIPs.joined(separator: ", "))。通常是路由器、WARP 或某些『翻墙工具』全局接管 DNS 导致。")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("修复（一行命令永久 override，跟 WARP 无关）：")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(hostsFixCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack {
                Button {
                    copyToClipboard(hostsFixCommand)
                } label: {
                    Label("复制命令", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                if let confirmation = copyConfirmation {
                    Text(confirmation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private struct HealthSummary {
        let icon: String
        let color: Color
        let label: String
    }

    private static func summarise(_ h: NetworkProbe.HealthResult) -> HealthSummary {
        guard let code = h.statusCode else {
            return HealthSummary(icon: "questionmark.circle", color: .secondary, label: "")
        }
        switch code {
        case 200..<300:
            return HealthSummary(icon: "checkmark.circle.fill", color: .green,
                                 label: "HTTP \(code)  ·  \(h.elapsedMS) ms  ·  后端正常")
        case 401:
            return HealthSummary(icon: "lock.shield", color: .blue,
                                 label: "HTTP 401  ·  \(h.elapsedMS) ms  ·  后端通了，但 token 未通过 — token 还没填时这是预期")
        default:
            return HealthSummary(icon: "exclamationmark.triangle", color: .orange,
                                 label: "HTTP \(code)  ·  \(h.elapsedMS) ms")
        }
    }

    @ViewBuilder
    private func healthResultBlock(_ h: NetworkProbe.HealthResult) -> some View {
        if let err = h.transportError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
                Text("连接失败：\(err)  ·  \(h.elapsedMS) ms")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if h.statusCode != nil {
            let s = Self.summarise(h)
            HStack(spacing: 8) {
                Image(systemName: s.icon).foregroundStyle(s.color)
                Text(s.label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func runDNS() async {
        guard let host = parsedHost, !host.isEmpty else { return }
        isResolvingDNS = true
        let result = await NetworkProbe.resolve(host: host)
        dnsResult = result
        isResolvingDNS = false
    }

    private func runHealth() async {
        guard let url = URL(string: currentURLString.trimmingCharacters(in: .whitespaces)) else { return }
        isProbingHealth = true
        let result = await NetworkProbe.probeHealth(baseURL: url)
        healthResult = result
        isProbingHealth = false
    }

    /// Cross-platform pasteboard set. The whole section is wrapped in
    /// `#if os(macOS)` so we only need NSPasteboard here, but the
    /// helper stays small enough that an iOS port (if ever needed) is
    /// a one-line `#else` away.
    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copyConfirmation = "已复制"
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copyConfirmation = nil
                }
            }
        }
    }
}

// MARK: - v0.9 §5.W.5 设备管理 (macOS only)

/// `.sheet(item:)` needs `Identifiable`. The 6-digit code is unique per
/// active pairing window, so it's a fine stable id for the dialog's
/// presentation lifetime. Scoped to the view layer (the model itself stays
/// a plain response DTO).
extension PairInitiateResponse: Identifiable {
    public var id: String { code }
}

/// "设备管理" sub-section in the Connection tab. Lists the device tokens
/// (`GET /auth/devices`), lets the author revoke any one (trash + confirm
/// alert), and opens the "添加新设备" dialog which calls `pair_initiate`
/// and shows a QR code + 6-digit code + 10-minute countdown for a new
/// device to scan / type (§5.W.5).
private struct DeviceManagementSection: View {

    @EnvironmentObject private var store: DeviceStore

    /// Current backend URL string from the Connection form — embedded in the
    /// QR payload + the "复制配对信息" text.
    let currentURLString: String

    @State private var pendingRevoke: DeviceInfo?
    @State private var addDialogInfo: PairInitiateResponse?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer.and.iphone")
                Text("设备管理")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        if let info = await store.initiatePairing() {
                            addDialogInfo = info
                        }
                    }
                } label: {
                    if store.isMutating && addDialogInfo == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("添加新设备", systemImage: "plus")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isMutating)
            }
            Text("每台已配对设备持有独立 token，可单独撤销。在新设备上扫码或手输短码即可配对。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task { await store.load() }
        .sheet(item: $addDialogInfo) { info in
            AddDeviceDialog(info: info, currentURLString: currentURLString)
        }
        .alert("撤销设备", isPresented: Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRevoke = nil }
            Button("撤销", role: .destructive) {
                if let device = pendingRevoke {
                    Task { await store.revoke(id: device.deviceId) }
                }
                pendingRevoke = nil
            }
        } message: {
            if let device = pendingRevoke {
                Text("将撤销「\(device.deviceName)」的访问权限。如果这是你当前正在使用的设备，撤销后本机会立即被拒，需要重新配对。")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.devices.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else if store.devices.isEmpty {
            Text("还没有已配对的设备。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 6) {
                ForEach(store.sortedDevices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: DeviceInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.callout.weight(.medium))
                Text("创建 \(Self.dateFormatter.string(from: device.createdAt))  ·  上次使用 \(lastUsedLabel(device))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                pendingRevoke = device
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("撤销该设备")
            .disabled(store.isMutating)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.05))
        )
    }

    private func lastUsedLabel(_ device: DeviceInfo) -> String {
        guard let last = device.lastUsedAt else { return "从未" }
        return Self.dateFormatter.string(from: last)
    }
}

/// "添加新设备" dialog: shows the 6-digit short code (large monospaced), the
/// QR code (JSON-base64 of `PairingPayload`), a 10-minute countdown derived
/// from `expires_at`, a "复制配对信息" button, and "完成" to dismiss.
private struct AddDeviceDialog: View {

    @Environment(\.dismiss) private var dismiss

    let info: PairInitiateResponse
    let currentURLString: String

    /// Drives the countdown. Recomputed every second by the timer below.
    @State private var now = Date()
    @State private var copyConfirmation: String?

    /// Tick every second to refresh the countdown label.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Resolved backend URL (trimmed). Falls back to the production default
    /// if the field somehow holds garbage so the QR still carries *a* URL.
    private var resolvedURL: String {
        let trimmed = currentURLString.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Settings.defaultBackendURLString : trimmed
    }

    /// Optional trusted-IP override embedded in the QR (§5.W.2). When the
    /// author has a known HZ origin IP we ship it so the new device can skip
    /// a DNS round-trip / dodge a hijacked resolver. Omitted when unknown.
    private var ipOverride: String? {
        Settings.trustedBackendIPs.first
    }

    private var pairingPayload: PairingPayload {
        PairingPayload(url: resolvedURL, code: info.code, ipOverride: ipOverride)
    }

    /// The plain-text the "复制配对信息" button puts on the pasteboard so the
    /// author can AirDrop / iMessage it to a phone that can't scan.
    private var clipboardText: String {
        "LinoI 配对: \(resolvedURL) 码 \(info.code)"
    }

    /// Seconds remaining until `expires_at`, clamped at 0.
    private var remaining: TimeInterval {
        max(0, info.expiresAt.timeIntervalSince(now))
    }

    private var countdownLabel: String {
        let total = Int(remaining)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var isExpired: Bool { remaining <= 0 }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("添加新设备")
                    .font(.title2.weight(.semibold))
                Text("在新设备上扫描二维码，或手动输入下方短码完成配对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 6-digit code, large monospaced.
            Text(info.code)
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(isExpired ? Color.secondary : Color.primary)

            // QR code occupies the main body.
            qrView
                .frame(width: 220, height: 220)
                .opacity(isExpired ? 0.25 : 1.0)

            // Countdown.
            HStack(spacing: 6) {
                Image(systemName: isExpired ? "clock.badge.xmark" : "clock")
                    .foregroundStyle(isExpired ? Color.red : Color.secondary)
                Text(isExpired ? "短码已过期，请关闭后重新生成" : "剩余 \(countdownLabel)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isExpired ? Color.red : Color.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    copyToClipboard(clipboardText)
                } label: {
                    Label("复制配对信息", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                if let confirmation = copyConfirmation {
                    Text(confirmation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 340)
        .onReceive(ticker) { now = $0 }
    }

    @ViewBuilder
    private var qrView: some View {
        if let base64 = pairingPayload.base64Encoded(),
           let nsImage = QRCodeGenerator.makeNSImage(from: base64) {
            Image(nsImage: nsImage)
                .interpolation(.none)   // keep QR modules crisp when scaled
                .resizable()
                .scaledToFit()
        } else {
            // QR generation should never fail for this tiny payload, but if
            // it does the short code is still usable for manual entry.
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("二维码生成失败，请使用上方短码手动配对。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copyConfirmation = "已复制"
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copyConfirmation = nil
                }
            }
        }
    }
}
#endif
