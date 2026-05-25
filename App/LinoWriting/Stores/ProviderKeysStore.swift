import Foundation
import SwiftUI

/// Manages the list of OpenAI-compatible provider keys and the single global
/// "active" selection.
///
/// Per PROJECT_PLAN §5.E.6 this store fronts the 6 backend endpoints behind
/// `SettingsView`'s LLM Providers tab.
///
/// Mutations follow the conservative "reload-after-mutation" pattern used by
/// ChaptersStore: after a successful create/update/delete/setActive we re-fetch
/// list + active in lockstep so the UI always reflects authoritative server
/// state (especially since `api_key` returns masked from the backend and the
/// active summary references the same masked surface).
@MainActor
public final class ProviderKeysStore: ObservableObject {

    @Published public private(set) var items: [ProviderKey] = []
    @Published public private(set) var active: ActiveProviderKeySummary?
    /// §5.M / M-2: 三个 Agent 各自的 active 绑定。
    /// - Key 不存在(`activeAgents[.writer] == nil`) 表示尚未 fetch；
    /// - Value 是 `ActiveAgentKeyRead`，其中 `activeProviderKeyId == nil`
    ///   表示该 slot 显式未绑（fallback 走通用 active）。
    @Published public private(set) var activeAgents: [AgentRole: ActiveAgentKeyRead] = [:]
    @Published public private(set) var isLoading: Bool = false
    /// Set true while a create/update/delete/setActive call is in flight. The
    /// UI uses this to disable form buttons and avoid double-submits.
    @Published public private(set) var isMutating: Bool = false

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    /// Sorted by label (case-insensitive) for stable display ordering.
    public var sortedItems: [ProviderKey] {
        items.sorted { $0.keyLabel.localizedCaseInsensitiveCompare($1.keyLabel) == .orderedAscending }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        await reloadBoth()
    }

    /// Refresh list + 通用 active + 三个 per-agent active 全部并发。
    /// 用于初次 load 和每次 mutation 后保持 store 与服务器一致。
    private func reloadBoth() async {
        async let listTask = fetchList()
        async let activeTask = fetchActive()
        async let writerTask = fetchActiveAgent(.writer)
        async let extractorTask = fetchActiveAgent(.extractor)
        async let expanderTask = fetchActiveAgent(.expander)
        let (list, activeSummary, w, e, x) = await (
            listTask, activeTask, writerTask, extractorTask, expanderTask
        )
        if let list { items = list }
        if let activeSummary { active = activeSummary }
        // M-2 reviewer 🟡 #2: partial-failure semantics. When any of the
        // 5 parallel fetches errors (network blip, transient backend
        // 5xx), the per-fetch helper publishes to ErrorBus and returns
        // nil. We deliberately **preserve** the prior value in that slot
        // rather than wipe it — same shape as `fetchList`/`fetchActive`
        // leaving `items`/`active` untouched on failure. Trade-off: a
        // recently-deleted key whose per-agent fetch races a network
        // hiccup could leave a phantom "still active" entry in the
        // sidebar until the next successful reload. Acceptable for an
        // optimistic-eventual-consistency UI; documented here so future
        // maintainers don't read it as "always reflects authoritative
        // state" — only successful round-trips do.
        var nextAgents = activeAgents
        if let w { nextAgents[.writer] = w }
        if let e { nextAgents[.extractor] = e }
        if let x { nextAgents[.expander] = x }
        activeAgents = nextAgents
    }

    private func fetchList() async -> [ProviderKey]? {
        do {
            return try await api.listProviderKeys()
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    private func fetchActive() async -> ActiveProviderKeySummary? {
        do {
            return try await api.getActiveProviderKey()
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    private func fetchActiveAgent(_ role: AgentRole) async -> ActiveAgentKeyRead? {
        do {
            return try await api.getActiveAgentKey(agentRole: role)
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    /// Create a new key. On success the list is reloaded and the new key is
    /// returned so a caller (e.g. the edit sheet) can take next-step actions
    /// like "auto-mark as active if this is the first key".
    @discardableResult
    public func create(_ payload: ProviderKeyCreate) async -> ProviderKey? {
        isMutating = true
        defer { isMutating = false }
        do {
            let created = try await api.createProviderKey(payload)
            await reloadBoth()
            return created
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    @discardableResult
    public func update(id: String, payload: ProviderKeyUpdate) async -> ProviderKey? {
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await api.updateProviderKey(id: id, payload: payload)
            await reloadBoth()
            return updated
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    public func delete(id: String) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await api.deleteProviderKey(id: id)
            await reloadBoth()
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func setActive(id: String) async {
        isMutating = true
        defer { isMutating = false }
        do {
            let summary = try await api.setActiveProviderKey(id: id)
            // Optimistic update from the response; reload list too in case the
            // backend ever side-effects fields on activation.
            active = summary
            if let list = await fetchList() { items = list }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// §5.M / M-2: 设置/清除某 Agent 的 active key。
    /// - `providerKeyId == nil` → PUT `{provider_key_id: null}`，清回通用 fallback。
    /// - 后端在 key.agent_role 与 slot 不匹配时返 409 → ErrorBus 收到 conflict
    ///   消息（"key 与 agent 不匹配"），UI 不需要本地校验。
    public func setActiveAgentKey(agentRole: AgentRole, providerKeyId: String?) async {
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await api.setActiveAgentKey(
                agentRole: agentRole,
                providerKeyId: providerKeyId
            )
            // 乐观更新：只动这一格，其它两个 slot 保持。
            var next = activeAgents
            next[agentRole] = updated
            activeAgents = next
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }
}
