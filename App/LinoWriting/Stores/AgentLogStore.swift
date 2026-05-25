import Foundation
import SwiftUI

/// v0.7 §5.D / Phase D-log — backs the new "Agent 日志" tab inside
/// `SettingsView`. Pulls `agent_logs` rows from
/// `GET /api/v1/admin/logs` with optional `agent_name` filter and
/// `before` cursor pagination, surfaces errors via `ErrorBus`.
///
/// Design notes (intentional choices, not accidents):
///
/// - **Filter switch ⇒ full reload.** Switching the Picker can't append:
///   the new agent_name filter on the server side returns a different
///   slice, so we wipe `entries` and refetch from scratch. This matches
///   what `TimelineStore.setCharacter` does and avoids stale rows.
///
/// - **`hasMore` heuristic.** Backend has no count endpoint, so we use the
///   same simplification as `TimelineStore`: if a page comes back smaller
///   than `pageSize`, we know we hit the tail. A page exactly equal to
///   pageSize might still be the last page (off-by-one risk), but the
///   next `loadMore` will just return zero rows and the user sees no
///   visual glitch — they just trigger one extra harmless request.
///
/// - **Filter API mapping.** `AgentLogFilter.apiValue` returns `nil` for
///   `.all` so the URLQueryItem is omitted; the four agent values map
///   to the exact strings the backend writes into `agent_logs.agent_name`
///   (see `Backend/app/routers/chapters.py` calls — `expander`, `writer`,
///   `extractor`, `admin_reset`).
@MainActor
public final class AgentLogStore: ObservableObject {

    public enum AgentLogFilter: String, CaseIterable, Hashable {
        case all
        case expander
        case writer
        case extractor
        case adminReset

        /// Chinese label rendered in the Settings Picker.
        public var displayName: String {
            switch self {
            case .all: return "全部"
            case .expander: return "提纲展开"
            case .writer: return "写作"
            case .extractor: return "提取"
            case .adminReset: return "强制重置"
            }
        }

        /// What we send on the wire. `nil` for `.all` means: omit the param.
        public var apiValue: String? {
            switch self {
            case .all: return nil
            case .expander: return "expander"
            case .writer: return "writer"
            case .extractor: return "extractor"
            case .adminReset: return "admin_reset"
            }
        }
    }

    @Published public private(set) var entries: [AgentLog] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var hasMore: Bool = true
    @Published public private(set) var filter: AgentLogFilter = .all

    public let pageSize: Int
    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus, pageSize: Int = 50) {
        self.api = api
        self.errorBus = errorBus
        self.pageSize = pageSize
    }

    /// Wipe local state and fetch the first page from scratch. Call on
    /// first appear of the Settings tab and from the manual "刷新" button.
    public func load() async {
        entries = []
        hasMore = true
        await fetchPage(before: nil, replace: true)
    }

    /// Append the next older page (rows with `createdAt < entries.last`).
    /// No-op if a fetch is in-flight or we already exhausted the tail.
    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        await fetchPage(before: entries.last?.createdAt, replace: false)
    }

    /// Change the filter and reload from scratch.
    public func setFilter(_ next: AgentLogFilter) async {
        guard next != filter else { return }
        filter = next
        await load()
    }

    private func fetchPage(before: Date?, replace: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listAgentLogs(
                chapterId: nil,
                agentName: filter.apiValue,
                limit: pageSize,
                before: before
            )
            if replace {
                entries = page
            } else {
                entries.append(contentsOf: page)
            }
            if page.count < pageSize {
                hasMore = false
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }
}
