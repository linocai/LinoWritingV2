import SwiftUI

public struct Step3_DraftView: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    @State private var draft: String = ""
    @State private var isExpanded: Bool = true

    // PROJECT_PLAN §5.K.4 (字体): the body editor obeys the user's serif/sans
    // preference. Defaults to "serif" (set on `Settings.editorFontDesign` and
    // documented there). Reading via `@AppStorage` here gives live updates
    // when the value changes in another view — no manual notification path
    // needed. Titles remain sans (`ChapterToolbar`), only body changes.
    @AppStorage(Settings.editorFontDesignKey) private var fontDesignRaw: String = EditorFontDesign.serif.rawValue

    public init(chapter: Chapter) { self.chapter = chapter }

    private var visible: Bool {
        switch chapter.status {
        case .draft, .promptReady: return false
        default: return true
        }
    }

    private var readOnly: Bool {
        chapter.status == .finalized || chapter.status == .writing
    }

    /// Parses the persisted raw string back into the SwiftUI font design.
    /// Falls back to serif if the stored value is unrecognised (e.g. a
    /// downgrade from a future enum case).
    private var bodyFontDesign: Font.Design {
        (EditorFontDesign(rawValue: fontDesignRaw) ?? .serif).fontDesign
    }

    public var body: some View {
        if visible {
            StepCard(
                stepIndex: 3,
                title: "正文",
                subtitle: subtitle,
                isExpanded: $isExpanded,
                collapsed: false
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if case .streaming(let buffer, _) = chapterEditorStore.writingState {
                        streamingView(buffer: buffer)
                    } else {
                        editorView
                    }
                    HStack {
                        Text("\(displayedCount) 字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !readOnly && chapter.status == .draftReady {
                            Button("保存修改") {
                                Task { await chapterEditorStore.patchDraftText(draft) }
                            }
                            .disabled(draft == (chapter.draftText ?? ""))
                        }
                    }
                }
            }
            .onAppear { draft = chapter.draftText ?? "" }
            .onChange(of: chapter.draftText ?? "") { _, new in
                if case .streaming = chapterEditorStore.writingState { return }
                draft = new
            }
            .onDisappear {
                // K-3 follow-up (reviewer 🟡 #3): `ChapterEditorView` now uses
                // `.id(chapter.id)` to drive its asymmetric transition, which
                // tears this view down on chapter switch and would silently
                // drop any unsaved edits. Flush dirty drafts here so the user
                // never loses work just because they navigated away. The
                // store is an EnvironmentObject and outlives this view, so
                // the Task survives even though `self` does not.
                guard !readOnly,
                      chapter.status == .draftReady,
                      draft != (chapter.draftText ?? "") else { return }
                let pending = draft
                Task { await chapterEditorStore.patchDraftText(pending) }
            }
        }
    }

    private var subtitle: String {
        switch chapter.status {
        case .writing: return "Agent 正在写作中…"
        case .draftReady: return "可以直接修改，或重新生成"
        case .finalized: return "已完成，只读"
        default: return ""
        }
    }

    private var displayedCount: Int {
        if case .streaming(let buf, _) = chapterEditorStore.writingState { return buf.count }
        return draft.count
    }

    private func streamingView(buffer: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(buffer.isEmpty ? "等待 Agent 输出…" : buffer)
                    .font(.system(.body, design: bodyFontDesign))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("streamEnd")
            }
            .frame(minHeight: 320, maxHeight: 560)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            )
            .onChange(of: buffer) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("streamEnd", anchor: .bottom)
                }
            }
        }
    }

    private var editorView: some View {
        TextEditor(text: $draft)
            .font(.system(.body, design: bodyFontDesign))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 320, maxHeight: 720)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )
            .disabled(readOnly)
    }
}
