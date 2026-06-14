#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 5 — 设置 · 模型与密钥.
///
/// Pixel-exact to the handoff MODELS block (`LinoWriting.dc.html`):
///   - heading row: 模型 Key + subtitle ("OpenAI 兼容端点 · 密钥加密存储，只显示末
///     4 位") + 新增 primary button (`POST /provider_keys` via the shared
///     `ProviderKeyEditSheet`).
///   - provider-key cards: label + role badge (优化师/Writer/档案员/通用) + model
///     · provider · masked tail + ✎ 编辑 / ⌫ 删除.
///   - 各 Agent 使用的模型: three rows (优化师/Writer/档案员); each lists its
///     role-specific + generic keys as selectable options, selected高亮.
///     Selecting → `setActiveAgentKey`; role mismatch → backend 409 (already
///     surfaced via ErrorBus Toast). A generic key falls back when a row has no
///     explicit pick.
struct MacModelsSettingsSection: View {

    @EnvironmentObject private var store: ProviderKeysStore

    @State private var editingKey: ProviderKey?
    @State private var showCreateSheet = false
    @State private var pendingDelete: ProviderKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            keyHeader
            keyList
                .padding(.top, 14)
            activeHeader
                .padding(.top, 34)
            activeRows
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await store.load() }
        .sheet(isPresented: $showCreateSheet) { ProviderKeyEditSheet(existing: nil) }
        .sheet(item: $editingKey) { ProviderKeyEditSheet(existing: $0) }
        .alert("删除模型 Key", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let key = pendingDelete { Task { await store.delete(id: key.id) } }
                pendingDelete = nil
            }
        } message: {
            if let key = pendingDelete {
                Text("将删除「\(key.keyLabel)」。如果它正被某个 Agent 使用，删除后该 Agent 会回落到通用 Key。")
            }
        }
    }

    // MARK: - Keys

    private var keyHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("模型 Key")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                Text("OpenAI 兼容端点 · 密钥加密存储，只显示末 4 位")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.mutedText3)
            }
            Spacer()
            LWPrimaryButton(title: "新增", systemImage: "plus", height: 34, horizontalPadding: 15) {
                showCreateSheet = true
            }
        }
    }

    @ViewBuilder
    private var keyList: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if store.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "key").font(.system(size: 28, weight: .light)).foregroundStyle(LWColor.mutedText2)
                Text("还没有任何模型 Key").font(.system(size: 13)).foregroundStyle(LWColor.secondaryText)
                Text("点右上「新增」录入一组 OpenAI 兼容 endpoint。").font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.5)))
        } else {
            VStack(spacing: 10) {
                ForEach(store.sortedItems) { key in
                    MacProviderKeyCard(
                        key: key,
                        onEdit: { editingKey = key },
                        onDelete: { pendingDelete = key }
                    )
                }
            }
        }
    }

    // MARK: - Active per-agent

    private var activeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("各 Agent 使用的模型")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LWColor.titleText)
            Text("为每个 Agent 指定模型；未指定时回落到「通用」Key")
                .font(.system(size: 12.5))
                .foregroundStyle(LWColor.mutedText3)
        }
    }

    private var activeRows: some View {
        VStack(spacing: 14) {
            ForEach(MacRoleVocab.displayOrder, id: \.self) { role in
                MacActiveKeyRow(role: role)
            }
        }
    }
}

// MARK: - Provider key card

private struct MacProviderKeyCard: View {
    let key: ProviderKey
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(key.keyLabel)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(LWColor.bodyText)
                    roleBadge
                }
                HStack(spacing: 8) {
                    Text(key.modelName)
                    dot
                    Text(key.providerHint?.isEmpty == false ? key.providerHint! : "—")
                    dot
                    Text(key.apiKey).font(LWFont.mono(12))
                }
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText2)
            }
            Spacer(minLength: 8)
            LWIconButton(systemName: "pencil", size: 32, fontSize: 13, help: "编辑", action: onEdit)
            LWIconButton(systemName: "trash", foreground: LWColor.danger, size: 32, fontSize: 13, help: "删除", action: onDelete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.66)))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.09), lineWidth: 0.5)
        )
    }

    private var dot: some View {
        Text("·").foregroundStyle(LWColor.mutedText2.opacity(0.5))
    }

    private var roleBadge: some View {
        let isGeneric = key.agentRole == nil
        let label = key.agentRole.map { MacRoleVocab.label($0) } ?? "通用"
        return Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(isGeneric ? LWColor.mutedText : LWColor.accentText)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                (isGeneric ? LWColor.hex(0x787D96, opacity: 0.1) : LWColor.accentStart.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

// MARK: - Per-agent active key row

private struct MacActiveKeyRow: View {
    let role: AgentRole

    @EnvironmentObject private var store: ProviderKeysStore

    /// Keys eligible for this slot: this role's pinned keys + generic keys.
    private var options: [ProviderKey] {
        store.sortedItems.filter { $0.agentRole == nil || $0.agentRole == role }
    }

    private var selectedId: String? {
        store.activeAgents[role]?.activeProviderKeyId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacRoleVocab.label(role))
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(LWColor.bodyText)

            if options.isEmpty {
                Text("还没有可用的 Key。先在上面「新增」一个。")
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.mutedText3)
            } else {
                FlowOptions(options: options, selectedId: selectedId, role: role) { id in
                    Task { await store.setActiveAgentKey(agentRole: role, providerKeyId: id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
    }
}

/// Wrapping row of selectable key options (the handoff `flex-wrap` group).
private struct FlowOptions: View {
    let options: [ProviderKey]
    let selectedId: String?
    let role: AgentRole
    let onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options) { key in
                optionButton(key)
            }
        }
    }

    private func optionButton(_ key: ProviderKey) -> some View {
        let active = selectedId == key.id
        return Button {
            onPick(key.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.keyLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(active ? LWColor.accentDeep : LWColor.secondaryText2)
                Text(key.modelName)
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.mutedText3)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                (active ? LWColor.accentStart.opacity(0.14) : .white.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(active ? LWColor.accentStart.opacity(0.4) : LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }
}
#endif
