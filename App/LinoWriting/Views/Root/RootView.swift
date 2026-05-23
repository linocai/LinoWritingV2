import SwiftUI

public struct RootView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookshelfStore: BookshelfStore

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            Toast()
        }
        .sheet(isPresented: $appStore.showSettings) {
            SettingsView()
        }
        .task {
            if appStore.isConfigured {
                await bookshelfStore.load()
            }
        }
        .onChange(of: appStore.isConfigured) { _, configured in
            if configured {
                Task { await bookshelfStore.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appStore.isConfigured {
            SettingsView(isFirstRun: true)
        } else if let book = appStore.currentBook {
            WorkspaceView(book: book)
        } else {
            BookshelfView()
        }
    }
}
