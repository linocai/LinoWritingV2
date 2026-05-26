import SwiftUI

/// Create / edit a provider key. Per PROJECT_PLAN §5.E.6, the same sheet
/// serves both modes — pass `existing: nil` for create, or `existing: key`
/// for edit. In edit mode the API key field is left blank and acts as
/// "leave key unchanged if untouched" (matching backend's "missing field = no
/// change" semantics).
public struct ProviderKeyEditSheet: View {

    /// Preset menu entries. Each one carries default `base_url` and
    /// `model_name` values selected for v0.6:
    ///   xAI / Grok       → https://api.x.ai/v1 / grok-4
    ///   OpenAI           → https://api.openai.com/v1 / gpt-4o
    ///   OpenRouter       → https://openrouter.ai/api/v1 / anthropic/claude-sonnet-4.5
    ///   DeepSeek         → https://api.deepseek.com/v1 / deepseek-chat
    ///   Custom           → no preset
    public enum Preset: String, CaseIterable, Identifiable {
        case xai
        case openai
        case openrouter
        case deepseek
        case custom

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .xai: return "xAI / Grok"
            case .openai: return "OpenAI"
            case .openrouter: return "OpenRouter"
            case .deepseek: return "DeepSeek"
            case .custom: return "Custom"
            }
        }

        /// Backend-side `provider_hint` string. Returned as-is from §5.E.3 —
        /// the backend treats it as opaque, so we use simple lowercase tokens.
        public var providerHintValue: String? {
            switch self {
            case .custom: return nil
            default: return rawValue
            }
        }

        public var baseUrlDefault: String? {
            switch self {
            case .xai: return "https://api.x.ai/v1"
            case .openai: return "https://api.openai.com/v1"
            case .openrouter: return "https://openrouter.ai/api/v1"
            case .deepseek: return "https://api.deepseek.com/v1"
            case .custom: return nil
            }
        }

        public var modelNameDefault: String? {
            switch self {
            case .xai: return "grok-4"
            case .openai: return "gpt-4o"
            case .openrouter: return "anthropic/claude-sonnet-4.5"
            case .deepseek: return "deepseek-chat"
            case .custom: return nil
            }
        }

        public static func from(hint: String?) -> Preset {
            // Lowercase first so that legacy/manually-entered hints like
            // "XAI" or "OpenAI" round-trip to the right preset (E-3 reviewer 🟡 #9).
            guard let hint, let p = Preset(rawValue: hint.lowercased()) else { return .custom }
            return p
        }
    }

    @EnvironmentObject private var store: ProviderKeysStore
    @Environment(\.dismiss) private var dismiss

    private let existing: ProviderKey?

    // Form state
    @State private var keyLabel: String = ""
    @State private var preset: Preset = .xai
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var submitError: String?
    /// Track which fields the user has manually edited so we don't clobber
    /// their input when they change the preset picker.
    @State private var baseUrlEdited: Bool = false
    @State private var modelNameEdited: Bool = false
    /// §5.M / M-2: 用途绑定。`nil` = 通用键（默认）；其它三值锁死到对应
    /// Agent slot。编辑模式下记录原始值，submit 时只在变化时发 patch。
    @State private var agentRole: AgentRole? = nil

    public init(existing: ProviderKey? = nil) {
        self.existing = existing
    }

    private var isEditing: Bool { existing != nil }

    public var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    /// macOS v0.7 layout: 520-wide sheet, header + Form + footer row of
    /// Cancel / Save buttons with keyboard shortcuts. Unchanged from
    /// v0.7 — R-3 only adds the iOS branch.
    @ViewBuilder
    private var macOSBody: some View {
        VStack(spacing: 18) {
            header
            formContent
            submitErrorView
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "保存" : "添加") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || store.isMutating)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: prefill)
    }
    #endif

    #if os(iOS)
    /// v0.8 §5.R.5 — iOS adapts the sheet to native Settings.app idiom:
    /// `NavigationStack` chrome with Cancel / Save in `.topBarLeading` /
    /// `.topBarTrailing`, body is `.large` detent so the user gets a
    /// full sheet (form is dense). No fixed width — let the device
    /// decide.
    @ViewBuilder
    private var iOSBody: some View {
        NavigationStack {
            VStack(spacing: 12) {
                formContent
                submitErrorView
                    .padding(.horizontal, 16)
            }
            .navigationTitle(isEditing ? "编辑 Key" : "添加 LLM Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "保存" : "添加") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || store.isMutating)
                }
            }
            .onAppear(perform: prefill)
        }
        .presentationDetents([.large])
    }
    #endif

    /// Form body shared between macOS / iOS. Field-level differences
    /// (iOS URL keyboard) are already gated inside the rows below.
    @ViewBuilder
    private var formContent: some View {
        Form {
            Section {
                LabeledRow(label: "别名") {
                    TextField("如「主 Grok」", text: $keyLabel)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: "Provider") {
                    Picker("", selection: $preset) {
                        ForEach(Preset.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: preset) { _, newValue in
                        applyPresetDefaults(newValue)
                    }
                }
            }

            Section("Endpoint") {
                LabeledRow(label: "Base URL") {
                    TextField("https://...", text: $baseUrl)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .onChange(of: baseUrl) { _, _ in baseUrlEdited = true }
                }
                LabeledRow(label: "Model") {
                    TextField("grok-4", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: modelName) { _, _ in modelNameEdited = true }
                }
                LabeledRow(label: "API Key") {
                    SecureField(isEditing ? "留空保持不变" : "sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section {
                LabeledRow(label: "用途") {
                    Picker("", selection: $agentRole) {
                        Text("通用(任何 Agent 都可用)").tag(Optional<AgentRole>.none)
                        ForEach(AgentRole.allCases, id: \.self) { r in
                            Text("\(r.displayName) 专用").tag(Optional(r))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text("绑定到某 Agent 后,该 key 只能激活到对应 slot;通用 key 可激活到任意 slot。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var submitErrorView: some View {
        if let submitError {
            Text(submitError)
                .foregroundStyle(.red)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEditing ? "编辑 \(existing?.keyLabel ?? "")" : "添加 LLM Key")
                .font(.title2.weight(.semibold))
            Text(isEditing
                 ? "API Key 留空保持不变；其它字段按需更新。"
                 : "填入一组 OpenAI-compatible endpoint 配置。Base URL 末尾通常是 `/v1`。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prefill() {
        if let existing {
            keyLabel = existing.keyLabel
            preset = Preset.from(hint: existing.providerHint)
            baseUrl = existing.baseUrl
            modelName = existing.modelName
            agentRole = existing.agentRole
            // SecureField left blank: user must re-enter key to change it.
            apiKey = ""
            // Mark fields as user-edited so changing the picker won't wipe
            // the values they came in with.
            baseUrlEdited = true
            modelNameEdited = true
        } else {
            applyPresetDefaults(preset)
        }
    }

    private func applyPresetDefaults(_ p: Preset) {
        if !baseUrlEdited, let url = p.baseUrlDefault {
            baseUrl = url
        }
        if !modelNameEdited, let model = p.modelNameDefault {
            modelName = model
        }
        // For `custom` we leave fields alone — user is free to type whatever.
    }

    private var canSubmit: Bool {
        let trimmedLabel = keyLabel.trimmingCharacters(in: .whitespaces)
        let trimmedUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedUrl.isEmpty, !trimmedModel.isEmpty else {
            return false
        }
        // Create mode requires an API key. Edit mode allows blank (= leave
        // existing key unchanged).
        if !isEditing && trimmedKey.isEmpty { return false }
        return true
    }

    private func submit() async {
        submitError = nil
        let trimmedLabel = keyLabel.trimmingCharacters(in: .whitespaces)
        let trimmedUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let hint = preset.providerHintValue

        // Quick URL sanity check — backend will 422 if junk arrives anyway,
        // but a local hint avoids a roundtrip on obvious mistakes.
        if URL(string: trimmedUrl)?.scheme == nil {
            submitError = "Base URL 必须以 http(s):// 开头"
            return
        }

        if let existing {
            // §5.M / M-2 三态 agentRole 编码:
            //   - 未变 → .untouched(JSON 不含 agent_role 键)
            //   - 改为某 Agent → .set(role)
            //   - 改回"通用" → .clear(JSON `agent_role: null`,后端清回 generic)
            let roleUpdate: AgentRoleUpdate
            if agentRole == existing.agentRole {
                roleUpdate = .untouched
            } else if let r = agentRole {
                roleUpdate = .set(r)
            } else {
                roleUpdate = .clear
            }
            let payload = ProviderKeyUpdate(
                keyLabel: trimmedLabel == existing.keyLabel ? nil : trimmedLabel,
                providerHint: hint == existing.providerHint ? nil : hint,
                baseUrl: trimmedUrl == existing.baseUrl ? nil : trimmedUrl,
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
                modelName: trimmedModel == existing.modelName ? nil : trimmedModel,
                agentRole: roleUpdate
            )
            let result = await store.update(id: existing.id, payload: payload)
            if result != nil { dismiss() }
        } else {
            let payload = ProviderKeyCreate(
                keyLabel: trimmedLabel,
                providerHint: hint,
                baseUrl: trimmedUrl,
                apiKey: trimmedKey,
                modelName: trimmedModel,
                agentRole: agentRole
            )
            let result = await store.create(payload)
            if result != nil { dismiss() }
        }
    }
}

/// Small helper to keep label/control rows tidy in the Form.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 88, alignment: .leading)
            content()
        }
    }
}
