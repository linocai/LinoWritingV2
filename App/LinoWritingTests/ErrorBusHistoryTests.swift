import XCTest
@testable import LinoWriting

/// Phase N (§5.N) — ErrorBus rolling-history buffer + clear/dismiss
/// semantics, plus the 30-entry FIFO eviction policy. The visible Toast
/// behaviour (3s auto-dismiss for non-critical, sticky for 401) lives in
/// `Toast.swift` and is intentionally untested at this layer — these
/// tests only cover the bus's state machine.
@MainActor
final class ErrorBusHistoryTests: XCTestCase {

    func test_publish_growsHistoryAndDrivesCurrent() {
        let bus = ErrorBus()
        XCTAssertTrue(bus.history.isEmpty)
        XCTAssertNil(bus.current)

        bus.publish("第一条")
        XCTAssertEqual(bus.history.count, 1)
        XCTAssertEqual(bus.history.first?.message, "第一条")
        XCTAssertEqual(bus.current?.message, "第一条")

        bus.publish("第二条")
        XCTAssertEqual(bus.history.count, 2)
        // Newest is last in history (we render reversed in the view).
        XCTAssertEqual(bus.history.last?.message, "第二条")
        XCTAssertEqual(bus.current?.message, "第二条")
    }

    func test_publishAppError_recordsCriticalForUnauthorized() {
        let bus = ErrorBus()
        bus.publish(AppError.unauthorized("token 已失效"))

        XCTAssertEqual(bus.history.count, 1)
        XCTAssertEqual(bus.history.first?.message, "token 已失效")
        XCTAssertTrue(bus.history.first?.isCritical ?? false)
        XCTAssertEqual(bus.current?.message, "token 已失效")
        XCTAssertTrue(bus.current?.isCritical ?? false)
    }

    func test_history_evictsOldestPastLimit() {
        let bus = ErrorBus()
        let limit = ErrorBus.historyLimit  // 30 per plan §5.N

        // Publish limit+5 entries; history must cap at `limit`, dropping
        // the 5 oldest.
        for i in 1...(limit + 5) {
            bus.publish("msg-\(i)")
        }
        XCTAssertEqual(bus.history.count, limit)
        // The oldest 5 ("msg-1" .. "msg-5") are gone; the newest is
        // "msg-(limit+5)" at the tail.
        XCTAssertEqual(bus.history.first?.message, "msg-6")
        XCTAssertEqual(bus.history.last?.message, "msg-\(limit + 5)")
    }

    func test_notice_carriesTimestamp() {
        let before = Date()
        let bus = ErrorBus()
        bus.publish("有时间戳")
        let after = Date()

        guard let notice = bus.history.first else {
            return XCTFail("expected a notice")
        }
        // Timestamp was stamped at publish time, so it sits between
        // `before` and `after`. Asserting an exact value would be
        // flaky; the bracket check is sufficient and resists clock drift.
        XCTAssertGreaterThanOrEqual(notice.timestamp, before)
        XCTAssertLessThanOrEqual(notice.timestamp, after)
    }

    func test_clearHistory_emptiesBufferAndPreservesCurrent() {
        let bus = ErrorBus()
        bus.publish("一")
        bus.publish("二")
        XCTAssertEqual(bus.history.count, 2)
        XCTAssertNotNil(bus.current)

        bus.clearHistory()
        XCTAssertTrue(bus.history.isEmpty)
        // clearHistory does NOT touch `current`; the Toast remains
        // visible until the user explicitly dismisses or it auto-times
        // out. This is intentional — clearing the log is a "review tab"
        // action, not a "kill the active alert" action.
        XCTAssertNotNil(bus.current)
        XCTAssertEqual(bus.current?.message, "二")
    }

    func test_dismiss_clearsCurrentButKeepsHistory() {
        let bus = ErrorBus()
        bus.publish("会消失的 toast")
        XCTAssertEqual(bus.history.count, 1)
        XCTAssertNotNil(bus.current)

        bus.dismiss()
        // Toast hides…
        XCTAssertNil(bus.current)
        // …but the message stays in history so the user can re-read it
        // in the 最近错误 tab. This is the whole point of §5.N — the v0.6
        // Toast auto-dismiss could swallow long upstream messages.
        XCTAssertEqual(bus.history.count, 1)
        XCTAssertEqual(bus.history.first?.message, "会消失的 toast")
    }
}
