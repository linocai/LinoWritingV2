import XCTest
@testable import LinoWriting

/// R-4 (v0.8) — iOS-runtime sanity for ``ErrorBus``.
///
/// Mirrors a subset of ``ErrorBusHistoryTests`` (macOS bundle) so the
/// rolling buffer + critical-flag plumbing is confirmed to work the same
/// way under the iOS Simulator's Swift runtime (notably its dispatch on
/// `@Published` properties).
@MainActor
final class ErrorBusIOSTests: XCTestCase {

    func test_publish_appError_setsCurrentAndAppendsHistory() {
        let bus = ErrorBus()

        bus.publish(AppError.notFound("book"))

        XCTAssertEqual(bus.current?.message, "book")
        XCTAssertEqual(bus.history.count, 1)
        XCTAssertEqual(bus.history.last?.message, "book")
        XCTAssertFalse(bus.history.last?.isCritical ?? true)
    }

    func test_publish_unauthorized_isCritical() {
        let bus = ErrorBus()

        bus.publish(AppError.unauthorized("invalid token"))

        XCTAssertEqual(bus.current?.message, "invalid token")
        XCTAssertTrue(bus.current?.isCritical ?? false)
    }

    func test_dismiss_clearsCurrentButKeepsHistory() {
        let bus = ErrorBus()
        bus.publish(AppError.server("500"))

        bus.dismiss()

        XCTAssertNil(bus.current)
        XCTAssertEqual(bus.history.count, 1)
    }
}
