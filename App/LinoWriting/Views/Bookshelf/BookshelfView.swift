import SwiftUI

public struct BookshelfView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var timelineStore: TimelineStore

    @State private var bookToDelete: Book?

    public init() {}

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 18)
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                if bookshelfStore.isLoading && bookshelfStore.books.isEmpty {
                    ProgressView().padding(40)
                } else if bookshelfStore.books.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(bookshelfStore.sortedBooks) { book in
                            BookCardView(book: book)
                                .contentShape(Rectangle())
                                .onTapGesture { openBook(book) }
                                .contextMenu {
                                    Button("打开") { openBook(book) }
                                    Divider()
                                    Button(role: .destructive) { bookToDelete = book } label: {
                                        Text("删除")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .refreshable { await bookshelfStore.load() }
        }
        .sheet(isPresented: $bookshelfStore.showNewBookSheet) {
            NewBookSheet()
        }
        .alert("确定删除这本书吗？", isPresented: .constant(bookToDelete != nil), presenting: bookToDelete) { book in
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

    private var header: some View {
        HStack {
            Text("书架")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Button {
                appStore.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)

            Button {
                bookshelfStore.showNewBookSheet = true
            } label: {
                Label("新建书", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("还没有书。开一本新的，准备好想法即可。")
                .foregroundStyle(.secondary)
            Button("新建第一本书") { bookshelfStore.showNewBookSheet = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func openBook(_ book: Book) {
        appStore.openBook(book)
        bookStore.setBook(book)
        Task {
            await bookshelfStore.touch(book)
            async let chs: () = chaptersStore.load(bookId: book.id)
            async let chars: () = charactersStore.load(bookId: book.id)
            _ = await (chs, chars)
        }
    }
}
