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
    //
    // R-1 (v0.8) — rewrote ``iOSLayout`` from the v0.7 stub (editor + single
    // sheet for the right panel, no chapter sidebar at all) into the contract
    // defined in PROJECT_PLAN §5.R.3 / §5.R.4:
    //   - iPad  → ``NavigationSplitView`` with ChapterList sidebar, editor
    //              content, and RightPanel as the third (inspector) column.
    //   - iPhone → ``NavigationStack`` rooted at the editor, with two sheets
    //              (chapter list + right panel) reachable from the toolbar.
    //
    // R-1 detects iPad vs iPhone via ``UIDevice.current.userInterfaceIdiom``;
    // R-2 will swap that for ``@Environment(\.horizontalSizeClass)`` so iPad
    // multitasking (Split View / Slide Over) at compact width falls back to
    // the iPhone layout. See ``iOSLayout`` below — that's the single point of
    // change for R-2.

    #if !os(macOS)
    /// Inspector / sidebar visibility for the iPad ``NavigationSplitView``.
    /// R-1 keeps this naive (``.all`` by default — three columns open on iPad
    /// of any orientation); R-2 will drive this from size class +
    /// vertical/horizontal class so iPad portrait can default to
    /// ``.doubleColumn`` (sidebar + content) and reveal the inspector via the
    /// toolbar.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showChaptersSheet: Bool = false
    @State private var showRightPanelSheet: Bool = false

    /// Dispatcher — picks iPad vs iPhone layout once and hoists the shared
    /// ``onChange`` reactions here so we don't duplicate them on both
    /// branches.
    ///
    /// 🔵 R-2 entry point: replace the ``UIDevice.current.userInterfaceIdiom``
    /// check below with ``@Environment(\.horizontalSizeClass)`` (and
    /// ``verticalSizeClass`` if portrait/landscape behaviour diverges) so iPad
    /// Split View / Slide Over at compact width correctly falls back to the
    /// iPhone layout. The two branch views (``iPadLayout`` / ``iPhoneLayout``)
    /// should stay as-is — only the dispatch condition changes.
    private var iOSLayout: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
    }

    // MARK: iPad — NavigationSplitView (sidebar / content / inspector)

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChapterListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } content: {
            ChapterEditorView()
        } detail: {
            RightPanelView(tab: $rightPanelTab)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    leaveWorkspace()
                } label: {
                    Label("书架", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleInspectorColumn()
                } label: {
                    Label("辅助面板", systemImage: "rectangle.righthalf.inset.filled")
                }
            }
        }
        .toolbarRole(.editor)
        .toolbarBackground(.automatic, for: .navigationBar)
    }

    /// Cycles the third (inspector) column on iPad without disturbing the
    /// sidebar. Mirrors the macOS inspector-toggle behaviour.
    private func toggleInspectorColumn() {
        switch columnVisibility {
        case .all:
            columnVisibility = .doubleColumn
        default:
            columnVisibility = .all
        }
    }

    // MARK: iPhone — NavigationStack + two sheets

    private var iPhoneLayout: some View {
        NavigationStack {
            ChapterEditorView()
                .navigationTitle(book.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            leaveWorkspace()
                        } label: {
                            Label("书架", systemImage: "chevron.left")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showChaptersSheet = true
                        } label: {
                            Label("章节", systemImage: "list.bullet")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showRightPanelSheet = true
                        } label: {
                            Label("辅助面板", systemImage: "rectangle.righthalf.inset.filled")
                        }
                    }
                }
                .toolbarRole(.editor)
                .toolbarBackground(.automatic, for: .navigationBar)
        }
        .sheet(isPresented: $showChaptersSheet) {
            NavigationStack {
                ChapterListView()
                    .navigationTitle("章节")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showChaptersSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
            // Auto-dismiss the chapter picker once the user selects a chapter.
            // Mirrors the macOS narrow-width sheet behaviour.
            .onChange(of: chaptersStore.selectedChapterId) { _, _ in
                showChaptersSheet = false
            }
        }
        .sheet(isPresented: $showRightPanelSheet) {
            NavigationStack {
                RightPanelView(tab: $rightPanelTab)
                    .navigationTitle("辅助面板")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showRightPanelSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
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
