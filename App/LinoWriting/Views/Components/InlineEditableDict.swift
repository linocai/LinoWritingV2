import SwiftUI

/// Key-value pair list with inline add + per-row delete (for fields like `relationships`).
public struct InlineEditableDict: View {
    public let label: String?
    public let keyPlaceholder: String
    public let valuePlaceholder: String
    /// PROJECT_PLAN §5.B (Phase B-fld) — when `true`, render a small red
    /// `DotIndicator` next to the label. Mirrors `InlineEditableText`.
    public let showHighlight: Bool
    @Binding public var dict: [String: String]
    public let onChange: ([String: String]) -> Void

    @State private var draftKey: String = ""
    @State private var draftValue: String = ""

    public init(
        label: String? = nil,
        keyPlaceholder: String = "键",
        valuePlaceholder: String = "值",
        showHighlight: Bool = false,
        dict: Binding<[String: String]>,
        onChange: @escaping ([String: String]) -> Void = { _ in }
    ) {
        self.label = label
        self.keyPlaceholder = keyPlaceholder
        self.valuePlaceholder = valuePlaceholder
        self.showHighlight = showHighlight
        self._dict = dict
        self.onChange = onChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if showHighlight {
                        DotIndicator()
                            .help("Agent 在最近一次完成时改动过这个字段")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    row(key: key)
                }
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $draftKey)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 120)
                    Text("→").foregroundStyle(.secondary)
                    TextField(valuePlaceholder, text: $draftValue, onCommit: addDraft)
                        .textFieldStyle(.plain)
                    Button(action: addDraft) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func row(key: String) -> some View {
        let valueBinding = Binding(
            get: { dict[key] ?? "" },
            set: { newValue in
                dict[key] = newValue
                onChange(dict)
            }
        )
        HStack(spacing: 6) {
            Text(key)
                .font(.callout.weight(.medium))
                .frame(maxWidth: 120, alignment: .leading)
                .lineLimit(1)
            Text("→").foregroundStyle(.secondary)
            TextField("", text: valueBinding)
                .textFieldStyle(.plain)
            Button(action: { remove(key) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private func addDraft() {
        let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        dict[k] = v
        draftKey = ""
        draftValue = ""
        onChange(dict)
    }

    private func remove(_ key: String) {
        dict.removeValue(forKey: key)
        onChange(dict)
    }
}
