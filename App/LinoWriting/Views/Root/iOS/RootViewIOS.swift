#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P0) — the new iPhone navigation shell.
///
/// Replaces the old `appStore.currentBook`-driven two-way swap (Bookshelf ⇄
/// WorkspaceView) with a real `NavigationStack` 下钻 seam, the skeleton the
/// per-screen Phases (P2–P6) fill:
///
/// ```
/// NavigationStack(path:)
///   根: Bookshelf (large title「书架」)
///    └ push BookDetail(book)        — P3 横滑 6 段
///         └ push ChapterEdit(chapter) — P4 竖向三步流
///              └ .fullScreenCover Reader — P5（仅 finalized）
///   书架右上 ⚙ → .sheet 设置 — P6
/// ```
///
/// **P0 scope (this file):** stand up the stack so the app builds + launches
/// and the book下钻 push/pop works. The root and the book destination still
/// reuse the *existing* `BookshelfView` / `WorkspaceView` (un-redesigned) — the
/// later Phases swap them for the new Liquid Glass screens behind the same
/// navigation seam. The `.fullScreenCover` (reader, P5) and the deeper
/// `navigationDestination` for individual chapters (P4) are left as documented
/// mount points, not yet wired.
///
/// iOS-only — macOS routes through `MacShellView` in `RootView`, untouched.
struct RootViewIOS: View {
    @EnvironmentObject var appStore: AppStore

    var body: some View {
        if !appStore.isConfigured {
            // v1.0.1: single fixed shared API_TOKEN. First-run drops the author
            // into the connection shell to fill backend URL + token. v1.2.0 (GG,
            // P6) reskins it to the new iOS Liquid Glass 连接 card (reusing the
            // settings sheet's `IOSConnectionSettingsSection`); saving flips
            // `isConfigured` and the shell re-routes into the bookshelf.
            IOSFirstRunConnectionView()
        } else {
            // The navigation path is derived from `appStore.currentBook`: opening
            // a book (Bookshelf tap → `appStore.openBook`) pushes the workspace;
            // `leaveWorkspace`/`closeBook` clears it and pops back to the shelf.
            // This keeps the existing Stores-driven open/close lifecycle while
            // giving us a genuine NavigationStack instead of a manual view swap.
            NavigationStack(path: bookPath) {
                // v1.2.0 (GG, P2): the new iOS Liquid Glass shelf replaces the
                // legacy `BookshelfView` as the stack root.
                IOSBookshelfView()
                    .navigationDestination(for: Book.self) { book in
                        // v1.2.0 (GG, P3): the new iOS book-detail screen (横滑 6
                        // 段) replaces the legacy `WorkspaceView` behind the same
                        // navigation seam. Chapter rows inside push the chapter
                        // editor via destination-based `NavigationLink` (managed
                        // by the stack internally, so the `[Book]` path bridge is
                        // untouched). P4 swaps the chapter destination for the new
                        // three-step editor; P5 wires the reader `.fullScreenCover`.
                        BookDetailView(book: book)
                            .navigationBarBackButtonHidden(true)
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            // v1.2.0 (GG, P5): the immersive reading page covers the whole stack
            // when a finalized chapter is opened (`appStore.openReader`, wired in
            // P4's chapter editor). Mounting it here — not inside the chapter
            // editor — keeps prev/next navigation against any finalized chapter
            // alive even though the editor underneath only holds one chapter.
            // Whole-screen theme tint (night = entire shell dark + status bar
            // white) lives in `ReaderView_iOS`.
            .fullScreenCover(isPresented: readerPresented) {
                ReaderView_iOS()
            }
        }
    }

    /// Drives the reader `.fullScreenCover` off `appStore.readingChapterId`
    /// (set by the chapter editor's「阅读模式 ›」button). Dismissing the cover
    /// (swipe-down or「‹ 完成」) clears the reading chapter so the state stays
    /// in sync with the overlay.
    private var readerPresented: Binding<Bool> {
        Binding(
            get: { appStore.readingChapterId != nil },
            set: { presented in
                if !presented, appStore.readingChapterId != nil { appStore.closeReader() }
            }
        )
    }

    /// Bridges the legacy `appStore.currentBook` open/close lifecycle to a
    /// `NavigationStack` path. A single-element path: `[book]` when a book is
    /// open, empty otherwise. Setting it back to empty (system back swipe)
    /// closes the book so the Stores reset stays in sync.
    private var bookPath: Binding<[Book]> {
        Binding(
            get: { appStore.currentBook.map { [$0] } ?? [] },
            set: { newPath in
                if newPath.isEmpty {
                    if appStore.currentBook != nil { appStore.closeBook() }
                } else if let book = newPath.last, appStore.currentBook?.id != book.id {
                    appStore.openBook(book)
                }
            }
        )
    }
}
#endif
