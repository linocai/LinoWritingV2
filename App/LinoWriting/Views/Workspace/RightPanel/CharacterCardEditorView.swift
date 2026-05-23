import SwiftUI

public struct CharacterCardEditorView: View {
    public let character: Character

    @EnvironmentObject var charactersStore: CharactersStore

    /// Recommended frozen-area scalar fields (text), in display order.
    private let frozenScalarFields: [(key: String, label: String, multiline: Bool)] = [
        ("core_traits", "核心性格", true),
        ("appearance", "外貌", true),
        ("background", "背景", true),
        ("voice", "说话方式", true)
    ]

    /// Recommended live-area scalar fields.
    private let liveScalarFields: [(key: String, label: String, multiline: Bool)] = [
        ("current_status", "当前状态", true)
    ]

    public init(character: Character) { self.character = character }

    public var body: some View {
        ScrollView {
            // Card-shaped container parallel to TimelineTabView / SummariesTabView
            // (PROJECT_PLAN §5.K.4 第一段：角色卡也用 regularMaterial).
            VStack(alignment: .leading, spacing: 16) {
                header
                if charactersStore.pendingHighlightIds.contains(character.id) {
                    HStack(spacing: 6) {
                        DotIndicator()
                        Text("Agent 在最近一次完成时改动过这张卡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("我知道了") { charactersStore.select(character.id) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                frozenSection
                liveSection
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear {
            // Visiting clears the highlight.
            charactersStore.select(character.id)
        }
        .onChange(of: character.id) { _, newId in
            charactersStore.select(newId)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                InlineEditableText(
                    label: nil,
                    placeholder: "角色名",
                    text: nameBinding,
                    onCommit: { value in
                        Task { await charactersStore.updateName(character, to: value) }
                    }
                )
                .frame(maxWidth: 220)
            }
            HStack {
                Text("身份").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                InlineEditableText(
                    placeholder: "主角 / 配角 / 反派 / 路人",
                    text: roleBinding,
                    onCommit: { value in
                        Task { await charactersStore.updateRole(character, to: value) }
                    }
                )
            }
        }
    }

    // MARK: Frozen section

    private var frozenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                Text("冻结区").font(.headline)
                Text("用户定下来的角色定义，请慎改")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(frozenScalarFields, id: \.key) { spec in
                frozenTextRow(spec: spec)
            }
        }
    }

    private func frozenTextRow(spec: (key: String, label: String, multiline: Bool)) -> some View {
        let value = character.frozenFields.string(spec.key) ?? ""
        let binding = Binding<String>(
            get: { value },
            set: { _ in /* InlineEditableText writes via onCommit */ }
        )
        return InlineEditableText(
            label: spec.label,
            placeholder: "未填写",
            multiline: spec.multiline,
            commitOnReturn: !spec.multiline,
            text: binding,
            onCommit: { newValue in
                Task { await charactersStore.updateFrozenField(character, key: spec.key, value: .string(newValue)) }
            }
        )
    }

    // MARK: Live section

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                Text("活动区").font(.headline)
                Text("会随着剧情变化")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(liveScalarFields, id: \.key) { spec in
                liveTextRow(spec: spec)
            }
            goalsRow
            secretsRow
            abilitiesRow
            relationshipsRow
        }
    }

    private func liveTextRow(spec: (key: String, label: String, multiline: Bool)) -> some View {
        let value = character.liveFields.string(spec.key) ?? ""
        let binding = Binding<String>(get: { value }, set: { _ in })
        return InlineEditableText(
            label: spec.label,
            placeholder: "未填写",
            multiline: spec.multiline,
            commitOnReturn: !spec.multiline,
            text: binding,
            onCommit: { newValue in
                Task { await charactersStore.updateLiveField(character, key: spec.key, value: .string(newValue)) }
            }
        )
    }

    private var goalsRow: some View {
        tagsRow(key: "goals", label: "目标")
    }

    private var secretsRow: some View {
        tagsRow(key: "secrets_known", label: "知晓的秘密")
    }

    private var abilitiesRow: some View {
        tagsRow(key: "abilities", label: "能力 / 物品")
    }

    private func tagsRow(key: String, label: String) -> some View {
        let tagsBinding = Binding<[String]>(
            get: { character.liveFields.stringArray(key) },
            set: { _ in }
        )
        return InlineEditableTags(label: label, tags: tagsBinding) { newTags in
            Task { await charactersStore.updateLiveField(character, key: key, value: .from(strings: newTags)) }
        }
    }

    private var relationshipsRow: some View {
        let dictBinding = Binding<[String: String]>(
            get: { character.liveFields.stringDict("relationships") },
            set: { _ in }
        )
        return InlineEditableDict(
            label: "关系",
            keyPlaceholder: "对象",
            valuePlaceholder: "关系描述",
            dict: dictBinding
        ) { newDict in
            Task { await charactersStore.updateLiveField(character, key: "relationships", value: .from(dict: newDict)) }
        }
    }

    // MARK: Bindings to scalar header fields

    private var nameBinding: Binding<String> {
        Binding(
            get: { character.name },
            set: { _ in }
        )
    }

    private var roleBinding: Binding<String> {
        Binding(
            get: { character.role ?? "" },
            set: { _ in }
        )
    }
}
