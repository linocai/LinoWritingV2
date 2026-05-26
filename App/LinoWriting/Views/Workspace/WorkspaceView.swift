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
    // width >= wideBreakpoint            → sidebar + editor + inspector all visible
    // mediumBreakpoint <= width < wide   → sidebar + editor; inspector auto-collapsed (user can toggle)
    // width < mediumBreakpoint           → sidebar collapsed to menu sheet; inspector auto-collapsed
    //
    // v0.7.1 — replaced the previous "sheet drawer at narrow widths" approach
    // with the native ``.inspector(isPresented:)`` modifier. The inspector
    // attaches to the detail column as a real right-side pane (not a centred
    // sheet popup), supports drag-to-resize, and persists user toggle state
    // across width transitions until the responsive threshold flips.
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
    /// User-controlled sidebar visibility. Mirrors the width-based default but
    /// lets the user collapse the sidebar manually once it has been auto-expanded.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Whether the user has manually opened the sidebar sheet at narrow widths.
    @State private var showingSidebarSheet: Bool = false
    /// Inspector (右侧辅助面板) presentation. Bound to ``.inspector`` so the
    /// SwiftUI runtime owns the open/close animation; toolbar button toggles
    /// this directly, width-threshold transitions sync it via ``onChange``.
    @State private var showingInspector: Bool = true
    /// Caches the previous "should-inspector-be-shown-inline" boolean so we
    /// only force-sync the inspector on actual threshold crossings, not on
    /// every layout pass with the same resolution category.
    @State private var lastAutoInspectorShown: Bool = true

    @ViewBuilder
    private func macOSLayout(width: CGFloat) -> some View {
        // K-1 follow-up (🟡 1): on the first frame `GeometryReader` may report
        // width == 0, which would briefly classify the layout as narrow and
        // collapse the sidebar/inspector. Treat zero/negative width as "still
        // measuring" and assume the wide layout to avoid the flicker.
        let resolvedWidth = width > 0 ? width : Self.wideBreakpoint
        let autoShowInspector = resolvedWidth >= Self.wideBreakpoint
        let showSidebarInline = resolvedWidth >= Self.mediumBreakpoint

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            editor
                // v0.7.1 — native macOS 14 inspector: real right-side pane,
                // not a centred sheet. ``inspectorColumnWidth`` mirrors the
                // dimensions the previous detail column used so the visual
                // footprint stays familiar. The only toggle button lives in
                // ``commonToolbar`` below — no inspector-internal toolbar item
                // to avoid double-bound primary actions.
                .inspector(isPresented: $showingInspector) {
                    RightPanelView(tab: $rightPanelTab)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(book.title)
        .toolbar {
            commonToolbar(showSidebarInline: showSidebarInline)
        }
        .toolbarRole(.editor)
        .toolbarBackground(.automatic, for: .windowToolbar)
        .onChange(of: autoShowInspector) { _, shouldShow in
            // Width threshold actually crossed → snap inspector to the new
            // default. User's manual toggle within a single resolution
            // category is preserved because onChange only fires on real
            // transitions.
            showingInspector = shouldShow
            lastAutoInspectorShown = shouldShow
        }
        .onChange(of: showSidebarInline) { _, newValue in
            if newValue {
                showingSidebarSheet = false
                columnVisibility = .all
            } else {
                columnVisibility = .detailOnly
            }
        }
        .onAppear {
            // Establish initial column + inspector visibility for the current
            // width (onChange does not fire on first render).
            if width > 0 {
                columnVisibility = showSidebarInline ? .all : .detailOnly
                showingInspector = autoShowInspector
                lastAutoInspectorShown = autoShowInspector
            }
        }
        .sheet(isPresented: $showingSidebarSheet) {
            sidebarSheet
                .onChange(of: chaptersStore.selectedChapterId) { _, _ in
                    showingSidebarSheet = false
                }
        }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
    }

    @ToolbarContentBuilder
    private func commonToolbar(showSidebarInline: Bool) -> some ToolbarContent {
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
        // v0.7.1 — single inspector toggle at the trailing edge of the
        // toolbar. The icon (``rectangle.righthalf.inset.filled``) is the
        // macOS-standard "right inspector" symbol used by Pages/Numbers, and
        // visually distinct from the leading-side ``sidebar.left`` for the
        // chapter list — fixing the v0.7 confusion where both edges used
        // near-identical ``sidebar.*`` glyphs.
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector.toggle()
            } label: {
                Label(
                    showingInspector ? "隐藏辅助面板" : "显示辅助面板",
                    systemImage: "rectangle.righthalf.inset.filled"
                )
            }
            .help(showingInspector ? "隐藏辅助面板" : "显示辅助面板")
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
                    Button { showingRightPanel = true } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                    }
                }
            }
            .sheet(isPresented: $showingRightPanel) {
                RightPanelView(tab: $rightPanelTab).padding()
            }
            .toolbarRole(.editor)
            .toolbarBackground(.automatic, for: .navigationBar)
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
