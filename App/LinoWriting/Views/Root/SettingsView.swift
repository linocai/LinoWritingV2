import SwiftUI

/// App settings.
///
/// Per PROJECT_PLAN §5.E.6 the v0.6 settings surface is split into two tabs:
///   - **Connection** — backend base URL + API token (i.e. the v0.5 form)
///   - **LLM Providers** — multi-key management (list / add / edit / delete /
///     set-active)
///
/// First-run mode (`isFirstRun = true`) hides the LLM tab because the user
/// can't even reach the backend yet without first saving credentials.
public struct SettingsView: View {

    @EnvironmentObject var appStore: AppStore
    @Environment(\.dismiss) private var dismiss

    public var isFirstRun: Bool

    /// Tab selector. First-run mode forces `.connection`.
    private enum Tab: Hashable { case connection, providers }
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
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
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
