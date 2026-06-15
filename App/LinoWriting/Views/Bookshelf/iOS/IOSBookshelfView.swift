#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P2) — iPhone Liquid Glass bookshelf (the NavigationStack root).
///
/// Pixel-exact transcription of the handoff library screen
/// (`LinoWriting iOS.dc.html` 屏1 / README §1.书架):
///   - kicker "LINOWRITING" (13px / 600 / 0.18em / #8B90A6) + large title
///     "书架" (32px / 700 / #20232E); right two round 38px buttons:
///     ⚙ 设置 (glass) / ＋ 新建作品 (accent gradient, glow).
///   - subtitle "N 部作品 · 已连接" (14px / #9499AD); 已连接/未连接/连接中
///     tracks a lightweight `GET /health` probe (same logic as macOS shell).
///   - two-column `LazyVGrid` of `IOSBookCardView`, gap 16, padding `0 20 40`.
///   - tap card → `appStore.openBook` (drives the NavigationStack push via
///     `RootViewIOS.bookPath`) + `POST /books/{id}/touch` + load chapters/chars.
///   - ＋ → `IOSNewBookSheet` (title + 6 named swatches → `POST /books`).
///
/// Replaces the old `BookshelfView` as the iOS shelf root (`RootViewIOS`). The
/// `GET /books` load + `Toast` are owned by `RootView` (unchanged). iOS-only.
struct IOSBookshelfView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var environment: AppEnvironment

    @State private var health: HealthState = .checking

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                subtitle
                content
            }
        }
        .background(LWColor.hex(0xEEF0F7).ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $bookshelfStore.showNewBookSheet) {
            IOSNewBookSheet()
        }
        .task {
            await bookshelfStore.load()
            await refreshHealth()
        }
        .refreshable {
            await bookshelfStore.load()
            await refreshHealth()
        }
    }

    // MARK: - Header (kicker + large title + ⚙ / ＋)

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LINOWRITING")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.18 * 13) // 0.18em
                    .foregroundStyle(LWColor.mutedText2) // #8B90A6
                Text("书架")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.02 * 32) // -0.02em
                    .foregroundStyle(LWColor.titleText) // #20232E
            }
            Spacer()
            HStack(spacing: 10) {
                settingsButton
                newBookButton
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var settingsButton: some View {
        Button { appStore.showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(LWColor.hex(0x4A4D58))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.7), in: Circle())
                .overlay(
                    Circle().stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var newBookButton: some View {
        Button { bookshelfStore.showNewBookSheet = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LWColor.accentGradient, in: Circle())
                .shadow(color: LWColor.accentStop.opacity(0.8), radius: 8, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var subtitle: some View {
        Text("\(bookshelfStore.books.count) 部作品 · \(health.label)")
            .font(.system(size: 14))
            .foregroundStyle(LWColor.mutedText3) // #9499AD
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 18)
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
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(bookshelfStore.sortedBooks) { book in
                    Button { openBook(book) } label: {
                        IOSBookCardView(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
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
                .multilineTextAlignment(.center)
            Button("新建第一本作品") { bookshelfStore.showNewBookSheet = true }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LWColor.accentText)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 100)
    }

    // MARK: - Open (push via appStore.currentBook → RootViewIOS.bookPath)

    private func openBook(_ book: Book) {
        appStore.openBook(book) // pushes the workspace via the bridged path
        bookStore.setBook(book)
        Task {
            await bookshelfStore.touch(book) // POST /books/{id}/touch
            async let chs: () = chaptersStore.load(bookId: book.id)
            async let chars: () = charactersStore.load(bookId: book.id)
            _ = await (chs, chars)
        }
    }

    // MARK: - Health probe (subtitle 已连接 / 未连接 / 连接中)

    private func refreshHealth() async {
        guard let baseURL = environment.keychain.baseURL else {
            health = .offline
            return
        }
        health = .checking
        let result = await NetworkProbe.probeHealth(baseURL: baseURL)
        if let code = result.statusCode, (200..<500).contains(code) {
            health = .online
        } else {
            health = .offline
        }
    }

    private enum HealthState {
        case checking, online, offline
        var label: String {
            switch self {
            case .checking: return "连接中"
            case .online: return "已连接"
            case .offline: return "未连接"
            }
        }
    }
}
#endif
