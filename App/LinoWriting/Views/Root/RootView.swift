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
            // v1.0.1: auth is a single fixed shared API_TOKEN. Both macOS and
            // iOS first-run route to the same first-run SettingsView, where the
            // author fills in the backend URL + token. The v0.9 iOS-only
            // device-pairing screen (scan QR / enter 6-digit code) is gone.
            SettingsView(isFirstRun: true)
        } else if let book = appStore.currentBook {
            WorkspaceView(book: book)
        } else {
            BookshelfView()
        }
    }
}
