import XCTest
@testable import LinoWriting

/// v1.2.0 (GG, P0) — replaces the deleted `WorkspaceLayoutIOSTests` (which
/// pinned the now-removed iPad `NavigationSplitView` size-class dispatch).
///
/// iPad is gone (`TARGETED_DEVICE_FAMILY "1"`); the iOS app is an iPhone-only
/// `NavigationStack` 下钻 shell (`RootViewIOS`). These tests pin the **book
/// navigation-path bridge** contract that the shell uses to translate the
/// legacy `appStore.currentBook` open/close lifecycle into a `NavigationStack`
/// path, mirroring the production logic verbatim (same approach the old file
/// used — re-implement the rule in pure Swift so a refactor of `RootViewIOS`
/// must update this file too, surfacing the change for review).
///
/// Production logic under test (`RootViewIOS.bookPath`):
///   - get: `currentBook.map { [$0] } ?? []`  — single-element path or empty.
///   - set: empty path → close book; non-empty → open last book if different.
final class NavigationShellIOSTests: XCTestCase {

    // MARK: - get: currentBook → path

    func test_pathGet_noBook_isEmpty() {
        let path = pathFromCurrentBook(nil)
        XCTAssertTrue(path.isEmpty)
    }

    func test_pathGet_openBook_isSingleElement() {
        let book = makeBook(id: "b1")
        let path = pathFromCurrentBook(book)
        XCTAssertEqual(path, [book])
    }

    // MARK: - set: path → currentBook

    /// Empty path (system back swipe / "书架" button) → close the book so the
    /// Stores reset stays in sync.
    func test_pathSet_emptyPath_closesBook() {
        var currentBook: Book? = makeBook(id: "b1")
        applyPathSet([], to: &currentBook)
        XCTAssertNil(currentBook)
    }

    /// Pushing a book → open it.
    func test_pathSet_pushBook_opensBook() {
        var currentBook: Book? = nil
        let book = makeBook(id: "b1")
        applyPathSet([book], to: &currentBook)
        XCTAssertEqual(currentBook?.id, "b1")
    }

    /// Pushing the *same* book that is already open is a no-op (no redundant
    /// `openBook` that would re-trigger the Stores load).
    func test_pathSet_sameBook_isNoOp() {
        let book = makeBook(id: "b1")
        var currentBook: Book? = book
        var openCallCount = 0
        applyPathSet([book], to: &currentBook, onOpen: { openCallCount += 1 })
        XCTAssertEqual(openCallCount, 0)
        XCTAssertEqual(currentBook?.id, "b1")
    }

    /// Empty path while no book is open is a no-op (no redundant close).
    func test_pathSet_emptyWhenAlreadyClosed_isNoOp() {
        var currentBook: Book? = nil
        var closeCallCount = 0
        applyPathSet([], to: &currentBook, onClose: { closeCallCount += 1 })
        XCTAssertEqual(closeCallCount, 0)
    }

    // MARK: - Helpers — mirror `RootViewIOS.bookPath` verbatim

    private func pathFromCurrentBook(_ currentBook: Book?) -> [Book] {
        currentBook.map { [$0] } ?? []
    }

    /// Mirrors the `set:` closure of `RootViewIOS.bookPath`. The optional
    /// callbacks let a test observe whether open/close fired (the production
    /// closure calls `appStore.openBook` / `appStore.closeBook`).
    private func applyPathSet(
        _ newPath: [Book],
        to currentBook: inout Book?,
        onOpen: () -> Void = {},
        onClose: () -> Void = {}
    ) {
        if newPath.isEmpty {
            if currentBook != nil {
                currentBook = nil
                onClose()
            }
        } else if let book = newPath.last, currentBook?.id != book.id {
            currentBook = book
            onOpen()
        }
    }

    private func makeBook(id: String) -> Book {
        Book(id: id, title: "书 \(id)", createdAt: Date(), updatedAt: Date())
    }
}
