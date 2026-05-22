import SwiftUI

/// Tag/chip list with inline add + per-tag delete.
public struct InlineEditableTags: View {
    public let label: String?
    public let placeholder: String
    @Binding public var tags: [String]
    public let onChange: ([String]) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    public init(
        label: String? = nil,
        placeholder: String = "添加后回车",
        tags: Binding<[String]>,
        onChange: @escaping ([String]) -> Void = { _ in }
    ) {
        self.label = label
        self.placeholder = placeholder
        self._tags = tags
        self.onChange = onChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { idx, tag in
                    tagChip(text: tag, index: idx)
                }
                TextField(placeholder, text: $draft, onCommit: addDraft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 80)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func tagChip(text: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Button(action: { remove(at: index) }) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }

    private func addDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { draft = "" }
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        onChange(tags)
    }

    private func remove(at index: Int) {
        guard tags.indices.contains(index) else { return }
        tags.remove(at: index)
        onChange(tags)
    }
}

/// Minimal flow layout for SwiftUI; lays out children on rows with wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
