import SwiftUI

public struct CharacterCardListView: View {
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var pendingDelete: Character?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            // PROJECT_PLAN §5.K.4 (全局动画 — 角色卡切换): same transition
            // language as the chapter editor — `.id()` rebuilds the editor
            // sub-tree per character, asymmetric move/opacity gives a soft
            // slide-in. Outer `.animation(.smooth, value:)` keyed on the
            // selected id is what drives the transition.
            Group {
                if let character = charactersStore.selected() {
                    CharacterCardEditorView(character: character)
                        .id(character.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else {
                    emptyState
                }
            }
            .animation(.smooth(duration: 0.3), value: charactersStore.selected()?.id)
        }
        .sheet(isPresented: $charactersStore.showNewCharacterSheet) {
            NewCharacterSheet()
        }
        .alert("删除角色？", isPresented: .constant(pendingDelete != nil), presenting: pendingDelete) { character in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = character
                pendingDelete = nil
                Task { await charactersStore.delete(target) }
            }
        } message: { character in
            Text("删除「\(character.name)」时，TA 的所有时间线事件也会一并删除。")
        }
    }

    private var picker: some View {
        HStack(spacing: 8) {
            if charactersStore.characters.isEmpty {
                Text("还没有角色")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Menu {
                    ForEach(charactersStore.characters) { c in
                        Button {
                            charactersStore.select(c.id)
                        } label: {
                            HStack {
                                Text(c.name)
                                if charactersStore.pendingHighlightIds.contains(c.id) {
                                    DotIndicator()
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(charactersStore.selected()?.name ?? "选择角色")
                            .font(.callout.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
            }
            Spacer()
            if let character = charactersStore.selected() {
                Button(role: .destructive) {
                    pendingDelete = character
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button {
                charactersStore.showNewCharacterSheet = true
            } label: { Label("新建", systemImage: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("创建一张角色卡，让 Agent 严格遵守角色设定")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("新建角色") { charactersStore.showNewCharacterSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

public struct NewCharacterSheet: View {
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var role: String = ""
    @State private var isSubmitting: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Text("新建角色")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("名字").font(.callout.weight(.medium))
                TextField("角色名", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("身份（可选）").font(.callout.weight(.medium))
                TextField("主角 / 配角 / 反派 …", text: $role).textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    else { Text("创建") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func submit() {
        isSubmitting = true
        Task {
            _ = await charactersStore.create(
                name: name.trimmingCharacters(in: .whitespaces),
                role: role.trimmingCharacters(in: .whitespaces).isEmpty ? nil : role
            )
            isSubmitting = false
            dismiss()
        }
    }
}
