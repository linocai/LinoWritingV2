#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — the iPhone book-detail screen (the largest iOS screen).
///
/// Pushed by `RootViewIOS` as the `Book` navigation destination (replacing the
/// legacy `WorkspaceView`). Pixel-exact transcription of the handoff book-detail
/// (`LinoWriting iOS.dc.html` 屏2 / README §2.作品详情):
///   - glass nav bar: ‹ 书架 (pops the stack via `appStore.closeBook`) + ···
///     menu (导出整本 `GET /books/{id}/export` / 删除作品 `DELETE /books/{id}`);
///     large-title = book title (Songti).
///   - a horizontally-scrolling pill row of **5 segments** matching
///     `MacRightPanelTab` + 章节: 章节 / 角色 / 时间线 / 梗概 / 设定 (v1.3.0
///     JJ P6: 大纲 segment removed, whole outline module deleted).
///   - 5 vertically-stacked full-width content views (one per segment), each a
///     separate iOS view that reuses the same Stores the macOS Mac*Tab views do.
///
/// Chapter rows push the chapter editor — for P3 that destination is the legacy
/// `ChapterEditorView` wrapped by `IOSChapterEditPlaceholder` (P4 replaces it
/// with the new three-step Liquid Glass editor behind the same seam). iOS-only;
/// macOS keeps `MacWorkspaceView`, untouched.
struct BookDetailView: View {
    let book: Book

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var timelineStore: TimelineStore
    @EnvironmentObject var environment: AppEnvironment

    @State private var tab: IOSBookTab = .chapters
    @State private var showExportSheet = false
    @State private var showDeleteConfirm = false

    /// The book metadata the 设定 tab edits live against — `bookStore` is
    /// authoritative once loaded; falls back to the pushed-in `book`.
    private var currentBook: Book { bookStore.book ?? book }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            content
        }
        .background(LWColor.hex(0xEEF0F7).ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { ensureLoaded() }
        .sheet(isPresented: $showExportSheet) {
            IOSExportBookSheet(book: currentBook)
        }
        .alert("确定删除整本作品？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteBook() }
        } message: {
            Text("《\(currentBook.title)》及其所有章节、角色、时间线都会被删除，不可恢复。")
        }
    }

    // MARK: - Glass nav bar (‹ 书架 + ··· + large title + 6 segments)

    private var navBar: some View {
        VStack(spacing: 0) {
            // back + ··· row.
            HStack {
                Button { appStore.closeBook() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium))
                        Text("书架").font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(LWColor.accentText)
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("导出整本", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除作品", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LWColor.hex(0x4A4D58))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.7), in: Circle())
                        .overlay(Circle().stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)

            // large title (Songti book name).
            HStack {
                Text(currentBook.title)
                    .font(LWFont.songti(27, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            // horizontally-scrolling 6 segment pills.
            segmentBar
        }
        .background(
            // rgba(238,240,247,0.8) + blur — matches the handoff nav glass.
            LWColor.hex(0xEEF0F7, opacity: 0.8)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(LWMetrics.hairlineLight).frame(height: 0.5)
        }
    }

    private var segmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(IOSBookTab.allCases) { t in
                    let selected = tab == t
                    Button { tab = t } label: {
                        Text(t.label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(selected ? .white : LWColor.secondaryText2)
                            .padding(.horizontal, 15)
                            .frame(height: 32)
                            .background(
                                selected
                                    ? AnyShapeStyle(LWColor.accentStop)
                                    : AnyShapeStyle(LWColor.hex(0x787D96, opacity: 0.1)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Content (one scrolling section per tab)

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch tab {
                case .chapters:   IOSChaptersSection(book: currentBook)
                case .characters: IOSCharactersSection(book: currentBook)
                case .timeline:   IOSTimelineSection()
                case .summaries:  IOSSummariesSection()
                case .settings:   IOSBookSettingsSection(book: currentBook)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Lifecycle / actions

    private func ensureLoaded() {
        bookStore.setBook(book)
    }

    private func deleteBook() {
        let target = currentBook
        Task {
            await environment.bookshelfStore.delete(target)
            chaptersStore.reset()
            charactersStore.reset()
            timelineStore.reset()
            appStore.closeBook() // pops back to the shelf
        }
    }
}

// MARK: - Segment model (== MacRightPanelTab labels + 章节)

/// The 5 horizontally-scrolling segments of the iOS book-detail screen. Labels
/// are **identical** to `MacRightPanelTab` (角色 / 时间线 / 梗概 / 设定),
/// with 章节 prepended (macOS has a separate chapter sidebar; iOS folds it into
/// the first segment). The legacy `RightPanelView`'s 角色卡 / 摘要 / 世界设定
/// naming is deliberately NOT reused (it is the deprecated命名).
///
/// v1.3.0 (JJ) P6 — 大纲 case removed (whole outline module deleted).
enum IOSBookTab: String, CaseIterable, Identifiable {
    case chapters, characters, timeline, summaries, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chapters: return "章节"
        case .characters: return "角色"
        case .timeline: return "时间线"
        case .summaries: return "梗概"
        case .settings: return "设定"
        }
    }
}
#endif
