import Foundation
import SwiftUI

/// Lightweight global error bus. Stores publish to it; the top-level view shows a banner.
///
/// v0.7 §5.N — keeps `current` (drives the bottom-trailing Toast) plus a
/// rolling `history` of the most recent N notices so the user can review
/// errors that auto-dismissed (the Toast has a 3-second timeout for
/// non-critical events; long SSE/Extractor messages used to flash by
/// before the author could read them). The history is shown in the
/// SettingsView's "最近错误" tab.
@MainActor
public final class ErrorBus: ObservableObject {
    public struct Notice: Identifiable, Equatable {
        public let id: UUID
        public let message: String
        public let isCritical: Bool
        public let timestamp: Date

        public init(id: UUID = UUID(), message: String, isCritical: Bool, timestamp: Date = Date()) {
            self.id = id
            self.message = message
            self.isCritical = isCritical
            self.timestamp = timestamp
        }
    }

    /// Maximum number of notices retained in `history`. Once the buffer
    /// is full the oldest entry is dropped on every new publish. Plan
    /// §5.N.2 calls this out as "最近 30 条" — kept at 30 because that's
    /// enough to cover one writing session (each chapter typically
    /// generates at most a handful of failures), small enough that the
    /// list scroll stays useful, and dwarfed by the cost of the rest of
    /// the SwiftUI scene.
    public static let historyLimit = 30

    @Published public var current: Notice?
    /// Rolling buffer of recent notices, newest LAST. The "最近错误" tab
    /// renders this reversed so the newest appears at the top.
    @Published public private(set) var history: [Notice] = []

    public init() {}

    public func publish(_ error: AppError) {
        // 401 is handled by the AppStore to surface SettingsView; still show a banner.
        record(message: error.message, isCritical: error.isUnauthorized)
    }

    public func publish(_ message: String, critical: Bool = false) {
        record(message: message, isCritical: critical)
    }

    /// Clears `current` only — the Toast disappears, but the entry stays
    /// in `history` so the user can still re-read it from SettingsView.
    public func dismiss() { current = nil }

    /// Wipes the rolling history (does NOT touch `current`). Bound to
    /// the "清空" button in the 最近错误 tab.
    public func clearHistory() {
        history.removeAll()
    }

    // MARK: - Internal

    /// Single funnel for both `publish` overloads: stamps timestamp,
    /// drives `current`, and appends to `history` with FIFO eviction.
    /// Keeping this DRY so the two callers can't drift on which side
    /// effect gets applied to which.
    private func record(message: String, isCritical: Bool) {
        let notice = Notice(message: message, isCritical: isCritical)
        current = notice
        history.append(notice)
        if history.count > Self.historyLimit {
            // O(N) shift on a 30-element array — negligible cost, and
            // keeps the buffer contract trivially correct (a circular
            // buffer with an index pointer would be faster but harder
            // to reason about in tests / SwiftUI rendering).
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}
