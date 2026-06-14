#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) — macOS Liquid Glass redesign shell.
///
/// Owns the single-window state machine: 书架 ↔ 工作台, with the reader as an
/// overlay (ZStack top) and settings as a sheet, all driven by `AppStore`.
///
/// **Phase status**: 书架 (`MacBookshelfView`, Phase 2), 工作台
/// (`MacWorkspaceView`, Phase 3), 阅读页 (`ReaderView`, Phase 4) and 设置
/// (`MacSettingsView`, Phase 5) are all the new self-drawn glass screens. The
/// first-run path routes to `MacSettingsView(isFirstRun: true)` (连接 section);
/// the ⚙ gear opens `MacSettingsView()` as a sheet (see `RootView`).
///
/// iOS keeps its existing `RootView.content` path untouched (this file is
/// macOS-only).
struct MacShellView: View {
    @EnvironmentObject var appStore: AppStore

    var body: some View {
        ZStack {
            base
            if appStore.readingChapterId != nil {
                ReaderView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    @ViewBuilder
    private var base: some View {
        if !appStore.isConfigured {
            MacSettingsView(isFirstRun: true)
        } else if let book = appStore.currentBook {
            MacWorkspaceView(book: book)
        } else {
            MacBookshelfView()
        }
    }
}
#endif
