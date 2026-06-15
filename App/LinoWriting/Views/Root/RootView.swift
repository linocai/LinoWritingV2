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
            // surface (连接 / 模型与密钥 / 人格编辑 / 调用日志).
            MacSettingsView()
            #else
            // v1.2.0 (GG, P6): iOS settings is the new Liquid Glass grouped
            // sheet (连接 / 模型与密钥 / 人格编辑 / 调用日志, 砍「最近错误」tab),
            // replacing the legacy `SettingsView` Form. `.large` detent + grabber
            // per the handoff 设置 sheet.
            IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        // Phases fill.
        MacShellView()
        #else
        // v1.2.0 (GG, P0): iOS routes through the new `NavigationStack` shell
        // (`RootViewIOS`), the `#if os(iOS)` seam the per-screen Phases (P2–P6)
        // fill. The old `currentBook`-driven view swap is gone — book下钻 is now
        // a real push/pop. First-run gate + single-密钥 auth (v1.0.1) preserved
        // inside `RootViewIOS`.
        RootViewIOS()
        #endif
    }
}
