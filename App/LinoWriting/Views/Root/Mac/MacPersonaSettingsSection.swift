#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 5 — 设置 · 人格编辑.
///
/// Pixel-exact to the handoff PERSONA block (`LinoWriting.dc.html`): heading +
/// "给三个 Agent 各自定性格" subtitle, then three glass cards (优化师 / Writer /
/// 档案员) each with: role name + 默认/已自定义 badge + 恢复默认 button, a one-line
/// responsibility blurb, and a `system_prompt` editor.
///
/// Binds the existing `PersonaStore`:
///   - `GET /agent-personas` (load three rows)
///   - `PATCH /agent-personas/{role}` (保存; flips is_default → false → "已自定义")
///   - `POST /agent-personas/{role}/reset` (恢复默认; → "默认", only enabled when
///     edited)
struct MacPersonaSettingsSection: View {

    @EnvironmentObject private var store: PersonaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("人格编辑")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LWColor.titleText)
                .padding(.bottom, 4)
            Text("给三个 Agent 各自定性格 —— 优化师、Writer、档案员。每个一段话，能改能恢复默认。")
                .font(.system(size: 12.5))
                .foregroundStyle(LWColor.mutedText3)
                .padding(.bottom, 18)

            if store.isLoading && store.personas.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                VStack(spacing: 16) {
                    ForEach(MacRoleVocab.displayOrder, id: \.self) { role in
                        if let persona = store.persona(for: role) {
                            MacPersonaCard(persona: persona)
                                .id(persona.id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if store.personas.isEmpty { await store.load() } }
    }
}

// MARK: - Persona card

private struct MacPersonaCard: View {
    let persona: AgentPersona

    @EnvironmentObject private var store: PersonaStore

    /// Live edit buffer. Seeded from the row; re-seeded whenever the store's
    /// row changes identity/content (save or reset round-trip).
    @State private var text: String = ""

    private var role: AgentRole { persona.agentRole }
    private var mutating: Bool { store.isMutating(role) }
    /// Buffer diverged from the persisted prompt → 保存 is meaningful.
    private var dirty: Bool { text != persona.systemPrompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row
            HStack(spacing: 10) {
                Text(MacRoleVocab.label(role))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(LWColor.bodyText)
                badge
                Spacer()
                LWBorderedButton(title: "恢复默认", systemImage: "arrow.counterclockwise", foreground: LWColor.warning, height: 28) {
                    Task { await store.reset(role: role) }
                }
                .disabled(persona.isDefault || mutating)
                .opacity(persona.isDefault ? 0.45 : 1)
            }
            .padding(.bottom, 4)

            Text(MacRoleVocab.desc(role))
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(2)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            editor

            // Save row — only meaningful while the buffer is dirty.
            HStack {
                Spacer()
                LWPrimaryButton(title: "保存", height: 32, horizontalPadding: 18, enabled: dirty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !mutating) {
                    Task { await store.save(role: role, systemPrompt: text) }
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.62)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.09), lineWidth: 0.5)
        )
        .onAppear { text = persona.systemPrompt }
        .onChange(of: persona.systemPrompt) { _, newValue in
            // Re-seed after a save/reset round-trip so the buffer tracks server.
            text = newValue
        }
    }

    private var badge: some View {
        Text(persona.isDefault ? "默认" : "已自定义")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(persona.isDefault ? LWColor.mutedText : LWColor.success)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(
                (persona.isDefault ? LWColor.hex(0x787D96, opacity: 0.1) : LWColor.success.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .lineSpacing(4)
            .foregroundStyle(LWColor.bodyText)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 96)
            .background(
                LWColor.hex(0xFCFCFE, opacity: 0.8),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
            )
            .disabled(mutating)
    }
}
#endif
