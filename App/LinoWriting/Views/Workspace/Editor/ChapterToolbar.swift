import SwiftUI

public struct ChapterToolbar: View {
    let chapter: Chapter
    /// Owner (ChapterEditorView) flips this to true when the user taps
    /// "导入文本". The sheet is hosted on the parent so it survives toolbar
    /// re-renders triggered by `chapter.status` changes mid-import.
    let onImportTap: () -> Void

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var titleDraft: String

    public init(chapter: Chapter, onImportTap: @escaping () -> Void = {}) {
        self.chapter = chapter
        self.onImportTap = onImportTap
        _titleDraft = State(initialValue: chapter.title ?? "")
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text("第 \(chapter.index) 章")
                .font(.headline)
            TextField("章节标题（可选）", text: $titleDraft, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.title3)
                .frame(maxWidth: 360)
                .onChange(of: chapter.title ?? "") { _, new in titleDraft = new }
            StatusBadge(chapter.status)
            Spacer()
            // PROJECT_PLAN §5.A.6 / §5.A.7: "导入文本" sits parallel to
            // "展开提纲" / "写作" etc. Hidden in `writing` (SSE race per A-1
            // reviewer) and `finalized` (chapter immutable). Visible in
            // draft / prompt_ready / draft_ready — the backend white-list.
            if canImport {
                Button(action: onImportTap) {
                    Label("导入文本", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(chapterEditorStore.isImporting)
                .help("把已写好的章节正文导入，并可选择让 Agent 提取角色更新和时间线")
            }
            primaryActionButtons
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// Whitelist mirrors the backend's `ensure_chapter_status` set
    /// in `POST /chapters/{id}/import` — see PROJECT_PLAN §5.A.4.
    private var canImport: Bool {
        switch chapter.status {
        case .draft, .promptReady, .draftReady: return true
        case .writing, .finalized: return false
        }
    }

    @ViewBuilder
    private var primaryActionButtons: some View {
        switch chapter.status {
        case .draft:
            Button(action: expand) {
                Label("展开提纲", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(chapterEditorStore.isExpanding || (chapter.userPrompt ?? "").isEmpty)
        case .promptReady:
            HStack(spacing: 6) {
                Button {
                    Task { _ = await chapterEditorStore.expand(force: true); refreshList() }
                } label: {
                    Label("重新展开", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button(action: startWriting) {
                    Label("写作", systemImage: "pencil.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chapter.structuredPrompt?.chapterGoal.isEmpty != false)
            }
        case .writing:
            Button {
                chapterEditorStore.cancelStream()
            } label: {
                Label("取消写作", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
        case .draftReady:
            HStack(spacing: 6) {
                Button(action: startWriting) {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button(action: finalize) {
                    Label("完成", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chapterEditorStore.isFinalizing)
            }
        case .finalized:
            Button {
                Task { _ = await chapterEditorStore.reopen(); refreshList() }
            } label: {
                Label("重新打开", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        if trimmed != (chapter.title ?? "") {
            Task { await chapterEditorStore.patchTitle(trimmed); refreshList() }
        }
    }

    private func expand() {
        Task {
            _ = await chapterEditorStore.expand()
            refreshList()
        }
    }

    private func startWriting() {
        chapterEditorStore.startWriting { chapter in
            chaptersStore.upsert(chapter)
        }
    }

    private func finalize() {
        Task {
            if let result = await chapterEditorStore.finalize() {
                charactersStore.markUpdated(result.updatedCharacterIds)
                chaptersStore.upsert(result.chapter)
                // Refresh characters so live_fields are current.
                if let bookId = chapterEditorStore.chapter?.bookId {
                    await charactersStore.load(bookId: bookId)
                }
            }
        }
    }

    private func refreshList() {
        if let chapter = chapterEditorStore.chapter {
            chaptersStore.upsert(chapter)
        }
    }
}
