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
