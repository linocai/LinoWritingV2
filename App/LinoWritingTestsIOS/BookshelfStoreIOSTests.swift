import XCTest
@testable import LinoWriting

/// R-4 (v0.8) — confirms ``BookshelfStore`` CRUD works on iOS Simulator.
/// On iPhone the bookshelf is the primary entry point (R-1
/// `iPhoneLayout` toolbar "书架" button calls `leaveWorkspace()` to come
/// back here), and on iPad it sits behind the NavigationSplitView
/// sidebar. Both rely on the same store behaviour.
@MainActor
final class BookshelfStoreIOSTests: XCTestCase {

    func test_createBook_appendsAndSorts() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = BookshelfStore(api: mock, errorBus: bus)

        let book = await store.create(title: "iOS 上的测试书", coverColor: "#3A86FF")

        XCTAssertNotNil(book)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.sortedBooks.first?.title, "iOS 上的测试书")
    }

    func test_deleteBook_removesFromStore() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = BookshelfStore(api: mock, errorBus: bus)

        let book = await store.create(title: "待删除", coverColor: nil)
        XCTAssertEqual(store.books.count, 1)

        await store.delete(book!)

        XCTAssertEqual(store.books.count, 0)
    }
}
