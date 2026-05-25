import SwiftUI

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
    private enum Tab: Hashable { case connection, providers, errorLog, agentLogs }
    @State private var tab: Tab = .connection

    public init(isFirstRun: Bool = false) {
        self.isFirstRun = isFirstRun
    }

    public var body: some View {
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
        VStack(spacing: 18) {
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
                    placeholder: "http://localhost:8787",
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
                if !isFirstRun {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
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
