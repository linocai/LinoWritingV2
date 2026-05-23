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

    // Responsive breakpoints (see PROJECT_PLAN §5.K.3).
    //
    // width >= wideBreakpoint            → three panes expanded
    // mediumBreakpoint <= width < wide   → sidebar + editor; right panel as drawer
    // width < mediumBreakpoint           → sidebar collapsed to menu sheet; right panel as drawer
    private static let wideBreakpoint: CGFloat = 1100
    private static let mediumBreakpoint: CGFloat = 800

    public init(book: Book) { self.book = book }

    public var body: some View {
        #if os(macOS)
        GeometryReader { proxy in
            macOSLayout(width: proxy.size.width)
        }
        #else
        iOSLayout
        #endif
    }

    // MARK: macOS responsive layout

    #if os(macOS)
    /// User-controlled sidebar visibility for the two-column layouts. Mirrors
    /// the width-based default but lets the user collapse the sidebar manually
    /// once it has been auto-expanded.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Whether the user has manually opened the sidebar sheet at narrow widths.
    @State private var showingSidebarSheet: Bool = false
    /// Whether the user has manually opened the right panel sheet at narrow widths.
    @State private var showingRightPanelSheetMac: Bool = false

    @ViewBuilder
    private func macOSLayout(width: CGFloat) -> some View {
        let showRightPanelInline = width >= Self.wideBreakpoint
        let showSidebarInline = width >= Self.mediumBreakpoint

        Group {
            if showRightPanelInline {
                threeColumnLayout
            } else {
                twoColumnLayout(showSidebarInline: showSidebarInline)
            }
        }
        .onChange(of: showRightPanelInline) { _, newValue in
            // When the layout returns to wide, dismiss the right-panel sheet so
            // the inline pane and the sheet do not show the same content.
            if newValue { showingRightPanelSheetMac = false }
        }
        .onChange(of: showSidebarInline) { _, newValue in
            if newValue {
                showingSidebarSheet = false
                // Restore the sidebar column when widening back out.
                columnVisibility = .all
            } else {
                // Narrow layout — collapse the sidebar; sheet button takes over.
                columnVisibility = .detailOnly
            }
        }
        .onAppear {
            // Establish the initial column visibility for the current width
            // (onChange does not fire on first render).
            columnVisibility = showSidebarInline ? .all : .detailOnly
        }
        .sheet(isPresented: $showingSidebarSheet) {
            sidebarSheet
        }
        .sheet(isPresented: $showingRightPanelSheetMac) {
            rightPanelSheet
        }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
            // Picking a chapter from the sidebar sheet should close it.
            if showingSidebarSheet { showingSidebarSheet = false }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
    }

    /// Width ≥ 1100. Sidebar + editor + right panel.
    private var threeColumnLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            editor
        } detail: {
            RightPanelView(tab: $rightPanelTab)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(book.title)
        .toolbar { commonToolbar(showSidebarInline: true, showRightPanelInline: true) }
    }

    /// Width < 1100. Right panel is drawer-only. When `showSidebarInline` is
    /// false (width < 800), the sidebar is also drawer-only.
    private func twoColumnLayout(showSidebarInline: Bool) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            editor
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(book.title)
        .toolbar {
            commonToolbar(showSidebarInline: showSidebarInline, showRightPanelInline: false)
        }
    }

    @ToolbarContentBuilder
    private func commonToolbar(showSidebarInline: Bool, showRightPanelInline: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                leaveWorkspace()
            } label: {
                Label("书架", systemImage: "chevron.left")
            }
        }
        if !showSidebarInline {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingSidebarSheet = true
                } label: {
                    Label("章节", systemImage: "sidebar.left")
                }
            }
        }
        if !showRightPanelInline {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRightPanelSheetMac = true
                } label: {
                    Label("辅助面板", systemImage: "sidebar.right")
                }
            }
        }
    }

    private var sidebarSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("章节")
                    .font(.headline)
                Spacer()
                Button("完成") { showingSidebarSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            ChapterListView()
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private var rightPanelSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("辅助面板")
                    .font(.headline)
                Spacer()
                Button("完成") { showingRightPanelSheetMac = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            RightPanelView(tab: $rightPanelTab)
        }
        .frame(minWidth: 360, minHeight: 480)
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
