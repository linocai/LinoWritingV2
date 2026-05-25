import SwiftUI

public struct Step2_StructuredPromptView: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var draft: StructuredPrompt = StructuredPrompt()
    @State private var isExpanded: Bool = true
    @State private var dirty: Bool = false

    public init(chapter: Chapter) { self.chapter = chapter }

    private var visible: Bool {
        switch chapter.status {
        case .draft: return false
        default: return true
        }
    }

    private var collapsedByDefault: Bool {
        switch chapter.status {
        case .writing, .draftReady, .finalized: return true
        default: return false
        }
    }

    private var readOnly: Bool {
        chapter.status == .finalized || chapter.status == .writing
    }

    public var body: some View {
        if visible {
            StepCard(
                stepIndex: 2,
                title: "结构化提示",
                subtitle: "Agent 扩写出来的剧本骨架，可随时调整",
                isExpanded: $isExpanded,
                collapsed: collapsedByDefault
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    field("章节目标") {
                        TextEditor(text: $draft.chapterGoal)
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.2))
                            )
                            .disabled(readOnly)
                            .onChange(of: draft.chapterGoal) { _, _ in dirty = true }
                    }
                    field("必须发生") {
                        InlineEditableTags(tags: $draft.mustHappen) { _ in dirty = true }
                            .disabled(readOnly)
                    }
                    field("禁止发生") {
                        InlineEditableTags(tags: $draft.mustNotHappen) { _ in dirty = true }
                            .disabled(readOnly)
                    }
                    field("出场角色") {
                        charactersSelector
                    }
                    field("本章人格重点(0-2 个,emerge 重点)") {
                        focusTraitsEditor
                    }
                    field("场景设定") {
                        TextField("地点 / 时间 / 氛围", text: Binding(
                            get: { draft.sceneSetting ?? "" },
                            set: { draft.sceneSetting = $0.isEmpty ? nil : $0; dirty = true }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(readOnly)
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("视角").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { draft.narrativePov ?? .thirdPersonLimited },
                                set: { draft.narrativePov = $0; dirty = true }
                            )) {
                                ForEach(NarrativePOV.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .disabled(readOnly)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("目标字数").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("3000", value: Binding(
                                get: { draft.targetWordCount ?? 0 },
                                set: { draft.targetWordCount = $0 > 0 ? $0 : nil; dirty = true }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(readOnly)
                        }
                        Spacer()
                    }
                    field("备注") {
                        TextEditor(text: Binding(
                            get: { draft.extraNotes ?? "" },
                            set: { draft.extraNotes = $0.isEmpty ? nil : $0; dirty = true }
                        ))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.2))
                        )
                        .disabled(readOnly)
                    }
                    if !readOnly {
                        HStack {
                            Spacer()
                            Button("保存提示") {
                                Task { await chapterEditorStore.patchStructuredPrompt(draft); dirty = false }
                            }
                            .disabled(!dirty)
                        }
                    }
                }
            }
            .onAppear { draft = chapter.structuredPrompt ?? StructuredPrompt(); dirty = false }
            .onChange(of: chapter.id) { _, _ in
                draft = chapter.structuredPrompt ?? StructuredPrompt(); dirty = false
            }
        }
    }

    private var charactersSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            if charactersStore.characters.isEmpty {
                Text("还没有角色。先在右侧「角色卡」tab 创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(charactersStore.characters) { c in
                        characterChip(c)
                    }
                }
            }
        }
    }

    // PROJECT_PLAN §5.L.6 — focus_traits chip editor. Author-typed strings
    // (free-form rather than picked from a fixed pool — character traits in
    // v0.7 are themselves free-form, so a pool would be either misleadingly
    // small or constantly out of date). Cap at 2 per §5.L.3 contract.
    private var focusTraitsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                ForEach(Array(draft.focusTraits.enumerated()), id: \.offset) { idx, trait in
                    focusTraitChip(text: trait, index: idx)
                }
                if !readOnly && draft.focusTraits.count < 2 {
                    focusTraitInput
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            Text("Writer 会让这些特质在本章重点 emerge,其它特质少刷存在感。最多 2 个。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func focusTraitChip(text: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            if !readOnly {
                Button {
                    guard draft.focusTraits.indices.contains(index) else { return }
                    draft.focusTraits.remove(at: index)
                    dirty = true
                } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.purple.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private var focusTraitInput: some View {
        FocusTraitInputField(existing: draft.focusTraits) { trimmed in
            guard !trimmed.isEmpty,
                  !draft.focusTraits.contains(trimmed),
                  draft.focusTraits.count < 2 else { return }
            draft.focusTraits.append(trimmed)
            dirty = true
        }
    }

    private func characterChip(_ character: Character) -> some View {
        let selected = draft.charactersInvolved.contains(character.id)
        return Button {
            if readOnly { return }
            if selected {
                draft.charactersInvolved.removeAll { $0 == character.id }
            } else {
                draft.charactersInvolved.append(character.id)
            }
            dirty = true
        } label: {
            Text(character.name)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Tiny inline text field used by Step2's focus_traits chip editor. Lives in
/// its own `@State`-owning struct so the FlowLayout doesn't lose typing state
/// when sibling chips re-render. Commits on return; clears the draft after
/// commit. The parent controls visibility (e.g. hides this when chip count
/// reaches the §5.L.3 cap of 2).
private struct FocusTraitInputField: View {
    let existing: [String]
    let onCommit: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        TextField("加 trait 后回车", text: $draft, onCommit: {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = ""
            onCommit(trimmed)
        })
        .textFieldStyle(.plain)
        .frame(minWidth: 100)
    }
}
