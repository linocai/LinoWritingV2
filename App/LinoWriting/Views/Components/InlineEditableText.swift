import SwiftUI

/// Click-to-edit text: shows as a labelled text block; on tap becomes a TextField/TextEditor
/// and commits on blur or Return (`commitOnReturn`).
public struct InlineEditableText: View {
    public let label: String?
    public let placeholder: String
    public let multiline: Bool
    public let commitOnReturn: Bool
    public let monospace: Bool
    @Binding public var text: String
    public let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var editing: Bool = false
    @FocusState private var focused: Bool

    public init(
        label: String? = nil,
        placeholder: String = "",
        multiline: Bool = false,
        commitOnReturn: Bool = true,
        monospace: Bool = false,
        text: Binding<String>,
        onCommit: @escaping (String) -> Void = { _ in }
    ) {
        self.label = label
        self.placeholder = placeholder
        self.multiline = multiline
        self.commitOnReturn = commitOnReturn
        self.monospace = monospace
        self._text = text
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if editing {
                editor
            } else {
                staticView
            }
        }
    }

    private var staticView: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(monospace ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { startEditing() }
    }

    @ViewBuilder
    private var editor: some View {
        Group {
            if multiline {
                TextEditor(text: $draft)
                    .font(monospace ? .system(.body, design: .monospaced) : .body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            } else {
                TextField(placeholder, text: $draft, onCommit: commitIfReturn)
                    .font(monospace ? .system(.body, design: .monospaced) : .body)
                    .textFieldStyle(.plain)
            }
        }
        .focused($focused)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 1)
        )
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func startEditing() {
        draft = text
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commitIfReturn() {
        if commitOnReturn { commit() }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focused = false
        if draft != text {
            text = draft
            onCommit(draft)
        }
    }
}
