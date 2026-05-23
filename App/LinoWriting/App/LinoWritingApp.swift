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
                .environmentObject(environment.errorBus)
                .frame(minWidth: 880, minHeight: 580)
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
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
