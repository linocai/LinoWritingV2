#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — 设置 · 人格编辑.
///
/// Pixel-aligned to the handoff PERSONA block (`LinoWriting iOS.dc.html`
/// L415–425): a "人格编辑 · 给三个 Agent 各自定性格" section header, then three
/// white cards (优化师 / Writer / 档案员) each with: role name + 默认/已自定义 badge
/// + 恢复默认 button, a one-line responsibility blurb, and a `system_prompt`
/// editor.
///
/// Binds the existing `PersonaStore`:
///   - `GET /agent-personas` (load three rows)
///   - `PATCH /agent-personas/{role}` (保存 on blur; flips is_default → false →
///     "已自定义")
///   - `POST /agent-personas/{role}/reset` (恢复默认; → "默认", only enabled when
///     edited)
///
/// The handoff commits the persona edit on `onBlur`; we keep the macOS dirty-
/// tracking so a blur with no change is a no-op (avoids spurious PATCHes).
/// Mirrors `MacPersonaSettingsSection`'s logic.
struct IOSPersonaSettingsSection: View {

    @EnvironmentObject private var store: PersonaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if store.isLoading && store.personas.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                VStack(spacing: 12) {
                    ForEach(IOSRoleVocab.displayOrder, id: \.self) { role in
                        if let persona = store.persona(for: role) {
                            IOSPersonaCard(persona: persona)
                                .id(persona.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .task { if store.personas.isEmpty { await store.load() } }
    }

    private var sectionHeader: some View {
        Text("人格编辑 · 给三个 Agent 各自定性格")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 7)
    }
}

// MARK: - Persona card

private struct IOSPersonaCard: View {
    let persona: AgentPersona

    @EnvironmentObject private var store: PersonaStore

    /// Live edit buffer. Seeded from the row; re-seeded whenever the store's
    /// row changes (save or reset round-trip).
    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var role: AgentRole { persona.agentRole }
    private var mutating: Bool { store.isMutating(role) }
    /// Buffer diverged from the persisted prompt → 保存 (PATCH) is meaningful.
    private var dirty: Bool { text != persona.systemPrompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row
            HStack(spacing: 9) {
                Text(IOSRoleVocab.label(role))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                badge
                Spacer()
                Button {
                    Task { await store.reset(role: role) }
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LWColor.warning)
                }
                .buttonStyle(.plain)
                .disabled(persona.isDefault || mutating)
                .opacity(persona.isDefault ? 0.45 : 1)
            }
            .padding(.bottom, 3)

            Text(IOSRoleVocab.desc(role))
                .font(.system(size: 11.5))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(2)
                .padding(.bottom, 11)
                .fixedSize(horizontal: false, vertical: true)

            editor
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Seed unconditionally on mount: the editor doesn't grab focus on
        // appear (unlike `LWTextArea`), but `.task(id:)` is still the safe
        // identity-keyed seed that won't clobber an in-progress edit.
        .task(id: persona.id) { text = persona.systemPrompt }
        .onChange(of: persona.systemPrompt) { _, newValue in
            // Re-seed after a save/reset round-trip — but only if not actively
            // editing, so the server echo doesn't overwrite the live buffer.
            if !focused { text = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            // Commit on blur (handoff `onBlur`), skipping no-op edits.
            if !isFocused, dirty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await store.save(role: role, systemPrompt: text) }
            }
        }
    }

    private var badge: some View {
        Text(persona.isDefault ? "默认" : "已自定义")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(persona.isDefault ? LWColor.mutedText : LWColor.success)
            .padding(.horizontal, 8)
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
            .focused($focused)
            .padding(11)
            .frame(minHeight: 92)
            .background(LWColor.hex(0xFBFBFD), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5)
            )
            .disabled(mutating)
    }
}
#endif
