#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 2 — macOS Liquid Glass bookshelf.
///
/// Pixel-exact transcription of the handoff bookshelf screen
/// (`LinoWriting.dc.html` / `README.md` §1.书架):
///   - centered container max 1080, padding `56 48 80`.
///   - header: kicker "书架" (13px / 600 / 0.3em / #8B90A6 / uppercase) +
///     h1 "我的作品" (34px / 700 / #20232E); right "+ 新建作品" primary button
///     (40 high, accent gradient, glow).
///   - grid: `LazyVGrid(.adaptive(minimum: 220))`, gap 22.
///   - cards: `BookCardGlassView`. Tap → open book + `POST /books/{id}/touch`.
///
/// Backs onto the existing `BookshelfStore` / `APIClient` (`GET /books`,
/// `POST /books`, `POST /books/{id}/touch`). Data is real. macOS-only — the
/// iOS bookshelf keeps `BookshelfView`.
struct MacBookshelfView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore

    @State private var bookToDelete: Book?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: LWMetrics.shelfMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 56)
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .sheet(isPresented: $bookshelfStore.showNewBookSheet) {
            MacNewBookSheet()
        }
        .alert(
            "确定删除这本书吗？",
            isPresented: .constant(bookToDelete != nil),
            presenting: bookToDelete
        ) { book in
            Button("取消", role: .cancel) { bookToDelete = nil }
            Button("删除", role: .destructive) {
                let target = book
                bookToDelete = nil
                Task { await bookshelfStore.delete(target) }
            }
        } message: { book in
            Text("《\(book.title)》及其所有章节、角色、时间线都会被删除。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("书架")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.3 * 13) // 0.3em
                    .foregroundStyle(LWColor.mutedText2) // #8B90A6
                    .textCase(.uppercase)
                Text("我的作品")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.01 * 34) // -0.01em
                    .foregroundStyle(LWColor.titleText) // #20232E
            }
            Spacer()
            newBookButton
        }
        .padding(.bottom, 38)
    }

    private var newBookButton: some View {
        Button { bookshelfStore.showNewBookSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("新建作品")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(height: LWMetrics.primaryButtonHeight) // 40
            .padding(.horizontal, 18)
            .background(LWColor.accentGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .shadow(color: LWColor.accentStop.opacity(0.5), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content (grid / empty / loading)

    @ViewBuilder
    private var content: some View {
        if bookshelfStore.isLoading && bookshelfStore.books.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        } else if bookshelfStore.books.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(bookshelfStore.sortedBooks) { book in
                    BookCardGlassView(book: book) { openBook(book) }
                        .contextMenu {
                            Button("打开") { openBook(book) }
                            Divider()
                            Button(role: .destructive) { bookToDelete = book } label: {
                                Text("删除")
                            }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(LWColor.mutedText2)
            Text("还没有作品。开一本新的，准备好想法即可。")
                .font(.system(size: 14))
                .foregroundStyle(LWColor.secondaryText)
            Button("新建第一本作品") { bookshelfStore.showNewBookSheet = true }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LWColor.accentText)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    // MARK: - Open

    private func openBook(_ book: Book) {
        appStore.openBook(book)
        bookStore.setBook(book)
        Task {
            await bookshelfStore.touch(book) // POST /books/{id}/touch
            async let chs: () = chaptersStore.load(bookId: book.id)
            async let chars: () = charactersStore.load(bookId: book.id)
            _ = await (chs, chars)
        }
    }
}
#endif
