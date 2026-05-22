import SwiftUI

public struct WorkspaceView: View {
    public let book: Book

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var timelineStore: TimelineStore

    @State private var rightPanelTab: RightPanelTab = .characters

    public init(book: Book) { self.book = book }

    public var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iOSLayout
        #endif
    }

    // MARK: macOS three-pane

    #if os(macOS)
    private var macOSLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            editor
                .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        } detail: {
            RightPanelView(tab: $rightPanelTab)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    leaveWorkspace()
                } label: {
                    Label("书架", systemImage: "chevron.left")
                }
            }
        }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
    }
    #endif

    // MARK: iOS adaptive

    #if !os(macOS)
    @State private var showingRightPanel: Bool = false
    private var iOSLayout: some View {
        NavigationStack {
            HStack(spacing: 0) {
                editor
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { leaveWorkspace() } label: {
                        Label("书架", systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingRightPanel = true } label: { Image(systemName: "sidebar.right") }
                }
            }
            .sheet(isPresented: $showingRightPanel) {
                RightPanelView(tab: $rightPanelTab).padding()
            }
        }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
    }
    #endif

    @ViewBuilder
    private var sidebar: some View {
        ChapterListView()
    }

    @ViewBuilder
    private var editor: some View {
        ChapterEditorView()
    }

    private func leaveWorkspace() {
        chapterEditorStore.reset()
        chaptersStore.reset()
        charactersStore.reset()
        timelineStore.reset()
        appStore.closeBook()
    }

    private func updateTimelineSelection() {
        let involved = chapterEditorStore.chapter?.structuredPrompt?.charactersInvolved ?? []
        if let firstId = involved.first(where: { id in charactersStore.characters.contains(where: { $0.id == id }) }) {
            if timelineStore.characterId != firstId {
                timelineStore.setCharacter(firstId)
                Task { await timelineStore.loadInitial() }
            }
        }
    }
}
