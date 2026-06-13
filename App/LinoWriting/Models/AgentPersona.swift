import Foundation

/// v1.0.0 EE §3.3 / §5.4 / §5.5 — an Agent's editable persona layer.
///
/// The persona is the DB-stored, App-editable `[人格]/[原则]/[边界]` block the
/// three Agents read at runtime (the fixed mechanism layer — schema / output
/// format / show-don't-tell rules — stays in backend code, NOT here). The App
/// edits exactly the `system_prompt` field the backend's `GET/PATCH
/// /agent-personas` returns / accepts (§5.5: "别自造别的").
///
/// `agentRole` is the primary key on the backend (`expander` | `writer` |
/// `extractor`) and reuses the existing `AgentRole` enum so the persona editor
/// and the per-Agent key picker share one role vocabulary. `isDefault == false`
/// means the author has edited it (drives the "已修改" badge); `reset` flips it
/// back to `true` by restoring `DEFAULT_PERSONAS[role]`.
///
/// Mirrors `AgentPersonaRead`:
/// `{ agent_role, system_prompt, is_default, updated_at }`.
public struct AgentPersona: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let agentRole: AgentRole
    public var systemPrompt: String
    public var isDefault: Bool
    public var updatedAt: Date

    /// `Identifiable` via the role (one row per role, role is the PK).
    public var id: AgentRole { agentRole }

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case systemPrompt = "system_prompt"
        case isDefault = "is_default"
        case updatedAt = "updated_at"
    }

    public init(
        agentRole: AgentRole,
        systemPrompt: String,
        isDefault: Bool,
        updatedAt: Date
    ) {
        self.agentRole = agentRole
        self.systemPrompt = systemPrompt
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }
}

/// Body for `PATCH /agent-personas/{role}` — `{ system_prompt }`. The backend
/// rejects an empty / whitespace-only string with 422 (its validator), so the
/// editor disables 保存 until the field is non-empty rather than relying on the
/// round-trip error.
public struct AgentPersonaUpdateRequest: Codable, Sendable {
    public var systemPrompt: String

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
    }

    public init(systemPrompt: String) {
        self.systemPrompt = systemPrompt
    }
}

/// Envelope for `GET /agent-personas`: `{ "personas": [ {…} x3 ] }`.
public struct AgentPersonaListEnvelope: Codable, Sendable {
    public var personas: [AgentPersona]

    public init(personas: [AgentPersona]) {
        self.personas = personas
    }
}

/// Envelope for `PATCH /agent-personas/{role}` and
/// `POST /agent-personas/{role}/reset`: `{ "persona": {…} }`.
public struct AgentPersonaEnvelope: Codable, Sendable {
    public var persona: AgentPersona

    public init(persona: AgentPersona) {
        self.persona = persona
    }
}
