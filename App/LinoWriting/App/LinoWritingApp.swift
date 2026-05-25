import SwiftUI

@main
struct LinoWritingApp: App {
    @StateObject private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.appStore)
                .environmentObject(environment.bookshelfStore)
                .environmentObject(environment.bookStore)
                .environmentObject(environment.charactersStore)
                .environmentObject(environment.chaptersStore)
                .environmentObject(environment.chapterEditorStore)
                .environmentObject(environment.timelineStore)
                .environmentObject(environment.providerKeysStore)
                .environmentObject(environment.agentLogStore)
                .environmentObject(environment.errorBus)
                // K-1 follow-up (🟡 5): window-wide minimum size kept here
                // for the macOS window resizer (`.windowResizability` reads
                // it). The shelf can present itself at narrower widths than
                // the workspace; future work may push this minimum into
                // `WorkspaceView` only and shrink the shelf minimum, but
                // moving it requires `.windowResizability(.contentSize)`
                // semantics changes that are out of K-2 scope.
                .frame(minWidth: 880, minHeight: 580)
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置...") { environment.appStore.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建书") { environment.bookshelfStore.showNewBookSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("新建章节") { environment.chaptersStore.showNewChapterSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(environment.appStore.currentBook == nil)
            }
        }
        #endif
    }
}
