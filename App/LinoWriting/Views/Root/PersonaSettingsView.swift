import SwiftUI

/// v1.0.0 EE §5.4 / §5.5 — the 人格 (Agent persona editor) Settings tab.
///
/// Three Agents (优化师 / Writer / 档案员), each a `[人格]/[原则]/[边界]`
/// TextEditor + 「保存」+「恢复默认」. When `is_default == false` (the author
/// has edited it) a "已修改" badge shows on that row. The App edits exactly the
/// `system_prompt` the backend returns/accepts — the fixed mechanism layer
/// (schema / output format) stays server-side and is NOT exposed here.
///
/// Mirrors the visual rhythm of the other Settings tabs (header + scrolling
/// content). Lives in its own file because `SettingsView.swift` is already
/// large; `SettingsView` references `PersonaSettingsView` by its `internal`
/// type name (same module).
struct PersonaSettingsView: View {

    @EnvironmentObject private var store: PersonaStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if store.personas.isEmpty {
                await store.load()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 人格")
                    .font(.title3.weight(.semibold))
                Text("调教三个 Agent 的口味与边界。这里编辑的是「人格层」（人格 / 原则 / 边界）；schema、输出格式等机制层固定在后端代码里，不在此处。改完点保存即时生效，可随时恢复默认。")
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
        if store.isLoading && store.personas.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.personas.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("还没有加载到人格")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点右上「刷新」从后端拉取三份人格。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.personas) { persona in
                        PersonaCard(persona: persona)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }
}

/// One Agent's persona editor: title + 已修改 badge + TextEditor + 保存 / 恢复默认.
private struct PersonaCard: View {

    @EnvironmentObject private var store: PersonaStore

    let persona: AgentPersona

    /// Editable draft. Seeded from `persona.systemPrompt`; re-seeded whenever
    /// the store row changes (after a save / reset round-trip) UNLESS the author
    /// has unsaved edits in flight.
    @State private var draft: String = ""
    @State private var dirty: Bool = false
    @State private var showResetConfirm: Bool = false

    /// Chinese display name for the Agent persona being edited. Reuses the
    /// per-Agent label vocabulary but with the role-flavoured names used in the
    /// plan (优化师 / Writer / 档案员).
    private var personaDisplayName: String {
        switch persona.agentRole {
        case .expander: return "优化师 (Expander)"
        case .writer: return "Writer"
        case .extractor: return "档案员 (Extractor)"
        }
    }

    private var isMutating: Bool { store.isMutating(persona.agentRole) }

    /// 保存 is enabled only when the draft is non-empty (backend 422s an empty
    /// prompt) AND differs from the stored text.
    private var canSave: Bool {
        dirty && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(personaDisplayName)
                    .font(.callout.weight(.semibold))
                if !persona.isDefault {
                    Text("已修改")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                } else {
                    Text("默认")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isMutating {
                    ProgressView().controlSize(.small)
                }
            }

            TextEditor(text: $draft)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .disabled(isMutating)
                .onChange(of: draft) { _, newValue in
                    dirty = (newValue != persona.systemPrompt)
                }

            HStack(spacing: 10) {
                Button("恢复默认") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(isMutating || persona.isDefault)

                Spacer(minLength: 0)

                Button("保存") {
                    Task {
                        await store.save(role: persona.agentRole, systemPrompt: draft)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isMutating || !canSave)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { seedIfNeeded() }
        .onChange(of: persona) { _, _ in seedIfNeeded() }
        .alert("恢复默认人格", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                Task {
                    if await store.reset(role: persona.agentRole) != nil {
                        // The store row now holds the default; re-seed picks it up.
                        dirty = false
                    }
                }
            }
        } message: {
            Text("将把「\(personaDisplayName)」的人格还原为出厂默认，你当前的修改会被覆盖。")
        }
    }

    /// Seed the editor from the store row only when the author has no unsaved
    /// edits — so a save/reset round-trip refreshes the text, but a re-render
    /// mid-typing doesn't clobber it.
    private func seedIfNeeded() {
        guard !dirty else { return }
        if draft != persona.systemPrompt {
            draft = persona.systemPrompt
        }
    }
}
