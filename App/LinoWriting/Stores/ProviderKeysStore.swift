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

    /// Refresh list + active concurrently. Used both on first load and after
    /// every successful mutation.
    private func reloadBoth() async {
        async let listTask = fetchList()
        async let activeTask = fetchActive()
        let (list, activeSummary) = await (listTask, activeTask)
        if let list { items = list }
        if let activeSummary { active = activeSummary }
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
}
