import SwiftUI

public struct RootView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookshelfStore: BookshelfStore

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            content
            Toast()
        }
        .sheet(isPresented: $appStore.showSettings) {
            #if os(macOS)
            // v1.1.0 (FF) Phase 5: macOS settings is the new four-section glass
            // surface (连接 / 模型与密钥 / 人格编辑 / 调用日志). iOS keeps the
            // legacy `SettingsView`.
            MacSettingsView()
            #else
            SettingsView()
            #endif
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
        #if os(macOS)
        // v1.1.0 (FF): macOS routes through the new Liquid Glass shell
        // (`MacShellView`), the `#if os(macOS)` seam that the per-screen
        // Phases fill. iOS keeps its existing path below untouched.
        MacShellView()
        #else
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
        #endif
    }
}
