#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — 设置 · 模型与密钥.
///
/// Pixel-aligned to the handoff MODELS block (`LinoWriting iOS.dc.html`
/// L389–413):
///   - 模型与密钥 heading row with a 「＋ 新增」 accent text button →
///     `ProviderKeyEditSheet(existing: nil)` (`POST /provider_keys`).
///   - provider-key grouped card: rows of label + role badge
///     (优化师/Writer/档案员/通用) + model · provider · masked tail + ✎ 编辑 /
///     ⌫ 删除 (`PATCH` / `DELETE /provider_keys/{id}`).
///   - 各 Agent 使用的模型 grouped card: three rows (优化师/Writer/档案员); each
///     lists its role-specific + generic keys as horizontally-scrolling chips,
///     selected高亮 → `setActiveAgentKey` (`PUT /settings/active_key/{role}`).
///     Role mismatch → backend 409 → ErrorBus Toast (no local validation).
///
/// Reuses the cross-platform `ProviderKeyEditSheet` (already has iOS chrome) and
/// the shared `ProviderKeysStore`; the visual shell is iOS grouped cards on the
/// `#F2F2F7` grid. Mirrors `MacModelsSettingsSection`'s logic.
struct IOSModelsSettingsSection: View {

    @EnvironmentObject private var store: ProviderKeysStore

    @State private var editingKey: ProviderKey?
    @State private var showCreateSheet = false
    @State private var pendingDelete: ProviderKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            keyHeader
            keyList
                .padding(.horizontal, 16)
            activeHeader
            activeRows
                .padding(.horizontal, 16)
        }
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
        HStack {
            Text("模型与密钥")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.6))
            Spacer()
            Button { showCreateSheet = true } label: {
                Text("＋ 新增")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LWColor.accentText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var keyList: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if store.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "key").font(.system(size: 26, weight: .light)).foregroundStyle(LWColor.mutedText2)
                Text("还没有任何模型 Key").font(.system(size: 13)).foregroundStyle(LWColor.secondaryText)
                Text("点右上「＋ 新增」录入一组 OpenAI 兼容 endpoint。").font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 0) {
                let keys = store.sortedItems
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    IOSProviderKeyRow(
                        key: key,
                        onEdit: { editingKey = key },
                        onDelete: { pendingDelete = key }
                    )
                    if index < keys.count - 1 {
                        Rectangle()
                            .fill(LWColor.hex(0x3C3C43, opacity: 0.08))
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Active per-agent

    private var activeHeader: some View {
        Text("各 Agent 使用的模型")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private var activeRows: some View {
        VStack(spacing: 0) {
            let roles = IOSRoleVocab.displayOrder
            ForEach(Array(roles.enumerated()), id: \.element) { index, role in
                IOSActiveKeyRow(role: role)
                if index < roles.count - 1 {
                    Rectangle()
                        .fill(LWColor.hex(0x3C3C43, opacity: 0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Provider key row

private struct IOSProviderKeyRow: View {
    let key: ProviderKey
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(key.keyLabel)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(LWColor.titleText)
                    roleBadge
                }
                Text("\(key.modelName) · \(key.providerHint?.isEmpty == false ? key.providerHint! : "—") · \(key.apiKey)")
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.mutedText2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            iconButton(symbol: "pencil", color: LWColor.secondaryText2, action: onEdit)
            iconButton(symbol: "trash", color: LWColor.danger, action: onDelete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func iconButton(symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(LWColor.hex(0xFBFBFD), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var roleBadge: some View {
        let isGeneric = key.agentRole == nil
        let label = key.agentRole.map { IOSRoleVocab.label($0) } ?? "通用"
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isGeneric ? LWColor.mutedText : LWColor.accentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (isGeneric ? LWColor.hex(0x787D96, opacity: 0.1) : LWColor.accentStart.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

// MARK: - Per-agent active key row

private struct IOSActiveKeyRow: View {
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
        VStack(alignment: .leading, spacing: 9) {
            Text(IOSRoleVocab.label(role))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(LWColor.bodyText)

            if options.isEmpty {
                Text("还没有可用的 Key。先在上面「＋ 新增」一个。")
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.mutedText3)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options) { key in
                            optionButton(key)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func optionButton(_ key: ProviderKey) -> some View {
        let active = selectedId == key.id
        return Button {
            Task { await store.setActiveAgentKey(agentRole: role, providerKeyId: key.id) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.keyLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(active ? LWColor.accentDeep : LWColor.secondaryText2)
                Text(key.modelName)
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.mutedText3)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                (active ? LWColor.accentStart.opacity(0.14) : .white.opacity(0.7)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(active ? LWColor.accentStart.opacity(0.4) : LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
#endif
