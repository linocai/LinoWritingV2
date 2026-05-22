import SwiftUI

public struct ChapterEditorView: View {
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore

    public init() {}

    public var body: some View {
        Group {
            if let chapter = chapterEditorStore.chapter {
                content(for: chapter)
            } else if chapterEditorStore.isLoading {
                ProgressView().padding(40)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.append")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("从左侧选一章，或新建一章开始")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(for chapter: Chapter) -> some View {
        VStack(spacing: 0) {
            ChapterToolbar(chapter: chapter)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    Step1_PromptInputView(chapter: chapter)
                    Step2_StructuredPromptView(chapter: chapter)
                    Step3_DraftView(chapter: chapter)
                }
                .padding(20)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
