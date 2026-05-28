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
            // v0.9 §5.W.5 (W-3): iOS first-launch routes to the full-screen
            // device-pairing screen (scan QR / enter 6-digit code) instead
            // of the macOS first-run SettingsView. macOS is the pairing
            // *source* and keeps its v0.8 SettingsView + banner flow.
            #if os(iOS)
            if appStore.needsDevicePairing {
                DevicePairView()
            } else {
                SettingsView(isFirstRun: true)
            }
            #else
            SettingsView(isFirstRun: true)
            #endif
        } else if let book = appStore.currentBook {
            WorkspaceView(book: book)
        } else {
            BookshelfView()
        }
    }
}
