import Foundation
import SwiftUI

/// Lightweight global error bus. Stores publish to it; the top-level view shows a banner.
@MainActor
public final class ErrorBus: ObservableObject {
    public struct Notice: Identifiable, Equatable {
        public let id = UUID()
        public let message: String
        public let isCritical: Bool
    }

    @Published public var current: Notice?

    public init() {}

    public func publish(_ error: AppError) {
        // 401 is handled by the AppStore to surface SettingsView; still show a banner.
        current = Notice(message: error.message, isCritical: error.isUnauthorized)
    }

    public func publish(_ message: String, critical: Bool = false) {
        current = Notice(message: message, isCritical: critical)
    }

    public func dismiss() { current = nil }
}
