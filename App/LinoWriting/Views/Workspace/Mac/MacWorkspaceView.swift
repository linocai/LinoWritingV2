#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — macOS Liquid Glass workspace (three columns).
///
/// Self-drawn three-column layout (`HStack { sidebar; editor; rightPanel }`),
/// **replacing** the old `NavigationSplitView` / `.inspector` `WorkspaceView`
/// on macOS. Pixel-exact transcription of the handoff 工作台
/// (`LinoWriting.dc.html` / `README.md` §2):
///   - title bar (46 high) — traffic-light gutter + ✦ 写作台 (back to shelf)
///     + centred book title + connection dot (health) + ⚙ settings.
///   - left chapter sidebar (~258, `.lwSidebar`).
///   - centre editor (flexible) — three-stage flow (一句话 / HERO directive /
///     正文) with SSE write reuse.
///   - right panel (~326, `.lwSidebar`, 5 tabs).
///
/// Reflow (§3.2.5): ≥1100 all three columns; 800–1100 right panel folds into a
/// toolbar-toggled drawer; <800 sidebar also folds (rare, near minWidth 1080).
///
/// Reuses the entire data layer (Stores / APIClient / SSEClient / Models). iOS
/// keeps `WorkspaceView`. macOS-only.
struct MacWorkspaceView: View {
    let book: Book

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var timelineStore: TimelineStore
    @EnvironmentObject var outlineStore: OutlineStore
    @EnvironmentObject var environment: AppEnvironment

    @State private var rightTab: MacRightPanelTab = .characters
    /// User-toggle for the right panel when it is in drawer mode (medium width).
    @State private var rightPanelOpen = true
    /// User-toggle for the sidebar when it is in pop-over mode (narrow width).
    @State private var sidebarOpen = true
    /// Connection dot state, refreshed by a lightweight health probe.
    @State private var health: HealthState = .checking

    private static let wideBreakpoint: CGFloat = 1100
    private static let mediumBreakpoint: CGFloat = 800

    /// The book metadata the editor / 设定 tab edits live against (bookStore is
    /// authoritative once loaded; falls back to the passed-in `book`).
    private var currentBook: Book { bookStore.book ?? book }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width > 0 ? proxy.size.width : Self.wideBreakpoint
            let showRightInline = width >= Self.wideBreakpoint
            let showSidebarInline = width >= Self.mediumBreakpoint

            VStack(spacing: 0) {
                titleBar(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
                bodyRow(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
            }
            .background(LWColor.hex(0xFCFCFE, opacity: 0.4))
            .onChange(of: showRightInline) { _, inline in
                if inline { rightPanelOpen = true }
            }
            .onChange(of: showSidebarInline) { _, inline in
                if inline { sidebarOpen = true }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { ensureLoaded() ; Task { await refreshHealth() } }
        .onChange(of: chaptersStore.selectedChapterId) { _, newId in
            if let id = newId { Task { await chapterEditorStore.load(chapterId: id) } }
        }
        .onChange(of: chapterEditorStore.chapter?.id) { _, _ in
            updateTimelineSelection()
        }
        .onChange(of: chapterEditorStore.chapter?.structuredPrompt?.charactersInvolved ?? []) { _, _ in
            updateTimelineSelection()
        }
    }

    // MARK: - Title bar (46 high glass)

    @ViewBuilder
    private func titleBar(showRightInline: Bool, showSidebarInline: Bool) -> some View {
        HStack(spacing: 8) {
            // traffic-light gutter (the real macOS window buttons live here).
            Color.clear.frame(width: 70, height: 1)

            if !showSidebarInline {
                LWIconButton(systemName: "sidebar.left", fontSize: 13, help: "章节") {
                    withAnimation(.easeOut(duration: 0.18)) { sidebarOpen.toggle() }
                }
            }

            logoChip

            Spacer(minLength: 8)
            Text(currentBook.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LWColor.bodyText.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 8)

            connectionChip
            LWIconButton(systemName: "gearshape", foreground: LWColor.hex(0x4A4D58), size: 28, fontSize: 14, help: "设置") {
                appStore.showSettings = true
            }
            if !showRightInline {
                LWIconButton(systemName: "sidebar.right", foreground: LWColor.hex(0x4A4D58), size: 28, fontSize: 13, help: "辅助面板") {
                    withAnimation(.easeOut(duration: 0.18)) { rightPanelOpen.toggle() }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .lwToolbar()
        .lwBottomSeparator()
    }

    private var logoChip: some View {
        Button { leaveWorkspace() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LWColor.logoGradient)
                    .frame(width: 16, height: 16)
                    .shadow(color: LWColor.hex(0x6A7BFF, opacity: 0.5), radius: 1.5, y: 1)
                Text("写作台")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LWColor.bodyText)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(LWColor.hex(0x787D96, opacity: 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
        .help("返回书架")
    }

    private var connectionChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(health.dotColor)
                .frame(width: 7, height: 7)
            Text(health.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(health.textColor)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(health.bgColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Body row (three columns + reflow)

    @ViewBuilder
    private func bodyRow(showRightInline: Bool, showSidebarInline: Bool) -> some View {
        HStack(spacing: 0) {
            if showSidebarInline {
                MacChapterSidebar(book: currentBook, onExport: {})
                    .frame(width: LWMetrics.sidebarWidth)
            }
            ZStack(alignment: .topLeading) {
                MacChapterEditor(book: currentBook, onRead: openReader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Narrow-width pop-over sidebar.
                if !showSidebarInline && sidebarOpen {
                    sidebarDrawer
                }
            }
            .frame(maxWidth: .infinity)

            if showRightInline {
                MacRightPanel(book: currentBook, tab: $rightTab)
                    .frame(width: LWMetrics.rightPanelWidth)
            } else if rightPanelOpen {
                MacRightPanel(book: currentBook, tab: $rightTab)
                    .frame(width: LWMetrics.rightPanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Narrow-width sidebar drawer — overlays the editor's leading edge.
    private var sidebarDrawer: some View {
        MacChapterSidebar(book: currentBook, onExport: {})
            .frame(width: LWMetrics.sidebarWidth)
            .background(.regularMaterial)
            .overlay(alignment: .trailing) {
                Rectangle().fill(LWMetrics.hairline).frame(width: 0.5)
            }
            .shadow(color: LWColor.hex(0x141C3C, opacity: 0.18), radius: 18, x: 6)
            .transition(.move(edge: .leading))
            .zIndex(2)
    }

    // MARK: - Coordination (mirror WorkspaceView)

    private func ensureLoaded() {
        if chaptersStore.selectedChapterId == nil,
           let firstId = chaptersStore.sorted.first?.id {
            chaptersStore.selectedChapterId = firstId
        } else if let id = chaptersStore.selectedChapterId,
                  chapterEditorStore.chapter?.id != id {
            Task { await chapterEditorStore.load(chapterId: id) }
        }
        if outlineStore.loadedBookId != currentBook.id {
            Task { await outlineStore.load(bookId: currentBook.id) }
        }
    }

    private func updateTimelineSelection() {
        let involved = chapterEditorStore.chapter?.structuredPrompt?.charactersInvolved ?? []
        let preferred = involved.first(where: { id in charactersStore.characters.contains(where: { $0.id == id }) })
            ?? charactersStore.selectedCharacterId
            ?? charactersStore.characters.first?.id
        if let firstId = preferred, timelineStore.characterId != firstId {
            timelineStore.setCharacter(firstId)
            Task { await timelineStore.loadInitial() }
        }
    }

    private func openReader() {
        appStore.openReader(chapterId: chapterEditorStore.chapter?.id)
    }

    private func leaveWorkspace() {
        chapterEditorStore.reset()
        chaptersStore.reset()
        charactersStore.reset()
        timelineStore.reset()
        outlineStore.reset()
        appStore.closeBook()
    }

    // MARK: - Health probe

    private func refreshHealth() async {
        guard let baseURL = environment.keychain.baseURL else {
            health = .offline
            return
        }
        health = .checking
        let result = await NetworkProbe.probeHealth(baseURL: baseURL)
        if let code = result.statusCode, (200..<500).contains(code) {
            health = .online
        } else {
            health = .offline
        }
    }

    // MARK: - Connection dot state

    private enum HealthState {
        case checking, online, offline

        var label: String {
            switch self {
            case .checking: return "连接中"
            case .online: return "已连接"
            case .offline: return "未连接"
            }
        }
        var dotColor: Color {
            switch self {
            case .checking: return LWColor.warning
            case .online: return LWColor.success
            case .offline: return LWColor.danger
            }
        }
        var textColor: Color {
            switch self {
            case .checking: return LWColor.warning
            case .online: return LWColor.success
            case .offline: return LWColor.danger
            }
        }
        var bgColor: Color {
            switch self {
            case .checking: return LWColor.warning.opacity(0.12)
            case .online: return LWColor.success.opacity(0.12)
            case .offline: return LWColor.danger.opacity(0.1)
            }
        }
    }
}
#endif
