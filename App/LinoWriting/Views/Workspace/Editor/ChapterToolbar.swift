import SwiftUI

public struct ChapterToolbar: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var titleDraft: String

    public init(chapter: Chapter) {
        self.chapter = chapter
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
            primaryActionButtons
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var primaryActionButtons: some View {
        switch chapter.status {
        case .draft:
            Button("扩写", action: expand)
                .buttonStyle(.borderedProminent)
                .disabled(chapterEditorStore.isExpanding || (chapter.userPrompt ?? "").isEmpty)
        case .promptReady:
            HStack(spacing: 6) {
                Button("重新扩写") { Task { _ = await chapterEditorStore.expand(force: true); refreshList() } }
                    .buttonStyle(.bordered)
                Button("写作", action: startWriting)
                    .buttonStyle(.borderedProminent)
                    .disabled(chapter.structuredPrompt?.chapterGoal.isEmpty != false)
            }
        case .writing:
            Button("取消写作") { chapterEditorStore.cancelStream() }
                .buttonStyle(.bordered)
        case .draftReady:
            HStack(spacing: 6) {
                Button("重新生成", action: startWriting)
                    .buttonStyle(.bordered)
                Button("完成", action: finalize)
                    .buttonStyle(.borderedProminent)
                    .disabled(chapterEditorStore.isFinalizing)
            }
        case .finalized:
            Button("重新打开") { Task { _ = await chapterEditorStore.reopen(); refreshList() } }
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
