import SwiftUI

public struct ChapterEditorView: View {
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore

    /// Sheet binding for the §5.A import flow. Lives on the outer view so it
    /// persists across the toolbar re-render that happens when the chapter
    /// transitions to `finalized` mid-submit.
    @State private var showImportSheet: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if let chapter = chapterEditorStore.chapter {
                content(for: chapter)
                    // PROJECT_PLAN §5.K.4 (全局动画 — 章节切换): rebuild the
                    // editor sub-tree when the chapter id changes so SwiftUI
                    // runs the .transition below. `.id()` plus the asymmetric
                    // transition gives a "slide-in from trailing" effect when
                    // the user picks a different chapter from the sidebar.
                    .id(chapter.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if chapterEditorStore.isLoading {
                ProgressView().padding(40)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drives the chapter-switch transition above. Without an outer
        // `.animation(.smooth, value:)` keyed on the same id, SwiftUI would
        // skip the .transition phase.
        .animation(.smooth(duration: 0.3), value: chapterEditorStore.chapter?.id)
        // PROJECT_PLAN §5.A.7 Phase A-2: import sheet host. Hosting it here
        // (rather than inside the toolbar) means the sheet content sees the
        // outer environment objects and survives toolbar rebuilds.
        .sheet(isPresented: $showImportSheet) {
            if let chapter = chapterEditorStore.chapter {
                ImportChapterSheet(chapter: chapter)
            }
        }
        // A-2 reviewer 🟡 #5: if the chapter gets cleared from under us while
        // the sheet is open (e.g. user navigates away, store reset), an empty
        // sheet would render without a cancel button. Force-dismiss instead.
        .onChange(of: chapterEditorStore.chapter?.id) { _, newId in
            if newId == nil && showImportSheet {
                showImportSheet = false
            }
        }
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
            ChapterToolbar(chapter: chapter, onImportTap: { showImportSheet = true })
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
        // PROJECT_PLAN §5.K.4 (全局动画 — ChapterEditor 状态切换):
        // 5-step card expand/collapse + toolbar button swaps are driven off
        // `chapter.status`. The single source of truth for that transition
        // lives here so the cards animate together rather than each card
        // resolving its own animation timing.
        .animation(.smooth(duration: 0.35), value: chapter.status)
    }
}
