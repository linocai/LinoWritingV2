import Foundation
import SwiftUI

/// v1.0.0 EE §5.4 / §5.5 — backs the 人格编辑 (persona editor) Settings tab.
///
/// Three operations over the DB-stored, App-editable persona layer:
///   - `load()`            → `GET /agent-personas` (three rows)
///   - `save(role:text:)`  → `PATCH /agent-personas/{role}` (is_default→false)
///   - `reset(role:)`      → `POST /agent-personas/{role}/reset` (is_default→true)
///
/// Same ErrorBus + "endpoint returns the fresh row" pattern as `OutlineStore`
/// / `DeviceStore`: a failed call publishes and leaves state intact; a
/// successful mutation replaces just the touched role's row in `personas`.
@MainActor
public final class PersonaStore: ObservableObject {

    /// The three persona rows in stable role order (expander/writer/extractor),
    /// as returned by the backend envelope. Empty until `load()` runs.
    @Published public private(set) var personas: [AgentPersona] = []
    @Published public private(set) var isLoading: Bool = false
    /// Per-role in-flight flag so the editor can disable just the row being
    /// saved/reset (not the whole panel).
    @Published public private(set) var mutatingRoles: Set<AgentRole> = []

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    /// Lookup helper for the editor's per-role section.
    public func persona(for role: AgentRole) -> AgentPersona? {
        personas.first { $0.agentRole == role }
    }

    public func isMutating(_ role: AgentRole) -> Bool {
        mutatingRoles.contains(role)
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            personas = try await api.listAgentPersonas()
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// 保存：overwrite a role's persona. Backend flips `is_default` → false.
    /// Caller must pass a non-empty string (the UI disables 保存 otherwise);
    /// an empty prompt would 422. Returns the updated row on success.
    @discardableResult
    public func save(role: AgentRole, systemPrompt: String) async -> AgentPersona? {
        mutatingRoles.insert(role)
        defer { mutatingRoles.remove(role) }
        do {
            let updated = try await api.patchAgentPersona(agentRole: role, systemPrompt: systemPrompt)
            replace(updated)
            return updated
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// 恢复默认：restore `DEFAULT_PERSONAS[role]`, flips `is_default` → true.
    @discardableResult
    public func reset(role: AgentRole) async -> AgentPersona? {
        mutatingRoles.insert(role)
        defer { mutatingRoles.remove(role) }
        do {
            let restored = try await api.resetAgentPersona(agentRole: role)
            replace(restored)
            return restored
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
        return nil
    }

    /// Replace (or insert, preserving role order) the row for `updated.agentRole`.
    private func replace(_ updated: AgentPersona) {
        if let idx = personas.firstIndex(where: { $0.agentRole == updated.agentRole }) {
            personas[idx] = updated
        } else {
            personas.append(updated)
        }
    }
}
