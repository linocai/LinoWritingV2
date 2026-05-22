import SwiftUI

public struct Step1_PromptInputView: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    @State private var text: String = ""
    @State private var isExpanded: Bool = true

    public init(chapter: Chapter) { self.chapter = chapter }

    private var collapsedByDefault: Bool {
        switch chapter.status {
        case .draft, .promptReady: return false
        case .writing, .draftReady, .finalized: return true
        }
    }

    private var readOnly: Bool {
        chapter.status == .finalized
    }

    public var body: some View {
        StepCard(
            stepIndex: 1,
            title: "想法",
            subtitle: "约 50 字描述本章想发生什么",
            isExpanded: $isExpanded,
            collapsed: collapsedByDefault
        ) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .frame(minHeight: 110, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.2))
                    )
                    .disabled(readOnly)
                    .onChange(of: text) { _, new in
                        // Debounce-on-blur isn't built into TextEditor on macOS;
                        // patch on submit & on the toolbar's "扩写" press.
                        _ = new
                    }
                HStack {
                    Text("\(text.count) 字")
                        .font(.caption)
                        .foregroundStyle(text.count > 80 ? .orange : .secondary)
                    Spacer()
                    if !readOnly {
                        Button("保存想法") {
                            Task { await chapterEditorStore.patchUserPrompt(text) }
                        }
                        .disabled(text == (chapter.userPrompt ?? ""))
                    }
                }
            }
        }
        .onAppear { text = chapter.userPrompt ?? "" }
        .onChange(of: chapter.userPrompt ?? "") { _, new in text = new }
    }
}

/// Reusable collapsible card used by all three steps.
public struct StepCard<Content: View>: View {
    let stepIndex: Int
    let title: String
    let subtitle: String?
    @Binding var isExpanded: Bool
    let collapsed: Bool
    @ViewBuilder let content: () -> Content

    public init(
        stepIndex: Int,
        title: String,
        subtitle: String?,
        isExpanded: Binding<Bool>,
        collapsed: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.stepIndex = stepIndex
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = isExpanded
        self.collapsed = collapsed
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Step \(stepIndex)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            if collapsed { isExpanded = false }
        }
    }
}
