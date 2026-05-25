import Foundation

/// Per-Agent role tag for a provider key. Mirrors the backend enum (§5.M / M-1):
///   - `nil`      = 通用键，可激活到任意 Agent slot（v0.6 行为）。
///   - `.writer`  = 仅可激活到 writer slot。
///   - `.extractor` = 仅可激活到 extractor slot。
///   - `.expander`  = 仅可激活到 expander slot。
///
/// Backend enforces this at PUT `/settings/active_key/{agent_role}` time — a
/// non-nil `agentRole` on the key restricts which slot it can land in (409
/// conflict otherwise).
public enum AgentRole: String, Codable, CaseIterable, Sendable, Hashable {
    case writer
    case extractor
    case expander

    /// Chinese display name used by per-agent picker / edit sheet.
    public var displayName: String {
        switch self {
        case .writer: return "Writer"
        case .extractor: return "Extractor"
        case .expander: return "Expander"
        }
    }
}

/// A configured upstream LLM provider key.
///
/// Per PROJECT_PLAN §5.E.3 the backend treats every entry as an OpenAI-compatible
/// endpoint: only `base_url`, `api_key` and `model_name` are used at request time;
/// `provider_hint` is a free-form UI label (xai / openai / openrouter / deepseek /
/// custom) used solely for grouping & iconography on the frontend.
///
/// The `apiKey` field in this DTO is always the masked form (`****xxxx`) — the
/// backend never echoes the full key back. Full keys travel one way only via
/// `ProviderKeyCreate.apiKey` / `ProviderKeyUpdate.apiKey`.
///
/// §5.M / M-1 adds `agentRole`: NULL = 通用键（默认），其它三值绑死到对应
/// Agent slot。`init(from:)` 用 `decodeIfPresent` 兜底老 payload（沿用
/// `Chapter.source` §5.A.6 模式），让升级路径上 v0.6 缓存解码不炸。
public struct ProviderKey: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public var keyLabel: String
    public var providerHint: String?
    public var baseUrl: String
    public var apiKey: String          // masked: "****xxxx"
    public var modelName: String
    public var agentRole: AgentRole?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
        case agentRole = "agent_role"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        keyLabel: String,
        providerHint: String? = nil,
        baseUrl: String,
        apiKey: String,
        modelName: String,
        agentRole: AgentRole? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
        self.agentRole = agentRole
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.keyLabel = try c.decode(String.self, forKey: .keyLabel)
        self.providerHint = try c.decodeIfPresent(String.self, forKey: .providerHint)
        self.baseUrl = try c.decode(String.self, forKey: .baseUrl)
        self.apiKey = try c.decode(String.self, forKey: .apiKey)
        self.modelName = try c.decode(String.self, forKey: .modelName)
        // M-2 / §5.M: 老 backend / 缓存可能没有 agent_role 字段 → 兜底 nil
        // (与通用键语义一致). 沿用 §5.A.6 Chapter.source fallback 模式.
        self.agentRole = try c.decodeIfPresent(AgentRole.self, forKey: .agentRole)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// Body for `POST /api/v1/provider_keys`. `apiKey` here is the FULL key —
/// the backend will store it and only return the masked form on subsequent reads.
///
/// §5.M / M-2 adds optional `agentRole`. `nil` = create as 通用键（可激活到
/// 任意 slot）. 后端默认也是 NULL，所以省略字段与显式 `nil` 等价。
public struct ProviderKeyCreate: Codable, Sendable {
    public var keyLabel: String
    public var providerHint: String?
    public var baseUrl: String
    public var apiKey: String
    public var modelName: String
    public var agentRole: AgentRole?

    enum CodingKeys: String, CodingKey {
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
        case agentRole = "agent_role"
    }

    public init(
        keyLabel: String,
        providerHint: String? = nil,
        baseUrl: String,
        apiKey: String,
        modelName: String,
        agentRole: AgentRole? = nil
    ) {
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
        self.agentRole = agentRole
    }
}

/// Body for `PATCH /api/v1/provider_keys/{id}`. Every field is optional —
/// fields left nil are not modified server-side.
///
/// Note: `apiKey` is sent only when the user re-enters a full key. The plan
/// (§5.E.3 / §5.E.6) is that leaving the SecureField blank means "keep the
/// existing key"; an empty string would be rejected with 422 by the backend.
///
/// §5.M / M-2 `agentRole` 三态语义（与后端 `exclude_unset` 对齐）:
///   - 未传字段（默认）  → JSON 里不含 `agent_role` 键 → 后端不动该字段
///   - `.set(.writer)`   → JSON `"agent_role": "writer"` → 后端写入
///   - `.clear`          → JSON `"agent_role": null`    → 后端清回通用键
/// 用 `AgentRoleUpdate` enum 而非 `Optional<AgentRole?>` 双重可选避免歧义。
public struct ProviderKeyUpdate: Encodable, Sendable {
    public var keyLabel: String?
    public var providerHint: String?
    public var baseUrl: String?
    public var apiKey: String?
    public var modelName: String?
    public var agentRole: AgentRoleUpdate

    enum CodingKeys: String, CodingKey {
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
        case agentRole = "agent_role"
    }

    public init(
        keyLabel: String? = nil,
        providerHint: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil,
        modelName: String? = nil,
        agentRole: AgentRoleUpdate = .untouched
    ) {
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
        self.agentRole = agentRole
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(keyLabel, forKey: .keyLabel)
        try c.encodeIfPresent(providerHint, forKey: .providerHint)
        try c.encodeIfPresent(baseUrl, forKey: .baseUrl)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        switch agentRole {
        case .untouched:
            break // 不写入 key，与 `encodeIfPresent` 同语义
        case .set(let role):
            try c.encode(role, forKey: .agentRole)
        case .clear:
            try c.encodeNil(forKey: .agentRole)
        }
    }
}

/// Tri-state for `ProviderKeyUpdate.agentRole`. See struct doc for semantics.
public enum AgentRoleUpdate: Sendable, Equatable {
    case untouched
    case set(AgentRole)
    case clear
}

/// Body for `PUT /api/v1/settings/active_provider_key`.
public struct ActiveProviderKeyUpdate: Codable, Sendable {
    public var providerKeyId: String

    enum CodingKeys: String, CodingKey {
        case providerKeyId = "provider_key_id"
    }

    public init(providerKeyId: String) {
        self.providerKeyId = providerKeyId
    }
}

/// Response shape from `GET` and `PUT /api/v1/settings/active_key/{agent_role}`
/// (§5.M / M-1). 比通用 active 多一个 `agentRole` 字段（让前端可以把三个
/// agent 的 active 装进同一个字典或列表）；其它字段与
/// `ActiveProviderKeySummary` 对齐，便于复用展示组件。
///
/// 所有字段都是可空：当 per-agent slot 未设置或指向的 key 已被删除时，
/// 后端返回 `activeProviderKeyId == nil`（实际行为是 fallback 到通用 active
/// 还是真正"未设置"，是后端 factory 的事；本结构只描述 slot 自身是否绑定）。
public struct ActiveAgentKeyRead: Codable, Equatable, Sendable, Hashable {
    public let agentRole: AgentRole
    public var activeProviderKeyId: String?
    public var keyLabel: String?
    public var providerHint: String?
    public var modelName: String?
    public var apiKeyMask: String?

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case activeProviderKeyId = "active_provider_key_id"
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case modelName = "model_name"
        case apiKeyMask = "api_key_mask"
    }

    public init(
        agentRole: AgentRole,
        activeProviderKeyId: String? = nil,
        keyLabel: String? = nil,
        providerHint: String? = nil,
        modelName: String? = nil,
        apiKeyMask: String? = nil
    ) {
        self.agentRole = agentRole
        self.activeProviderKeyId = activeProviderKeyId
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.modelName = modelName
        self.apiKeyMask = apiKeyMask
    }
}

/// Body for `PUT /api/v1/settings/active_key/{agent_role}` (§5.M / M-1).
///
/// `providerKeyId == nil` 显式表示"清回 generic fallback"（不是"未传"），
/// 与后端的"null = explicit clear"语义对齐。前端用 `JSONEncoder` 默认会把
/// `Optional.none` 字段省略，所以我们用自定义 encode 保证 nil 也 emit `null`。
public struct ActiveAgentKeyUpdate: Encodable, Sendable {
    public let providerKeyId: String?

    enum CodingKeys: String, CodingKey {
        case providerKeyId = "provider_key_id"
    }

    public init(providerKeyId: String?) {
        self.providerKeyId = providerKeyId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let id = providerKeyId {
            try c.encode(id, forKey: .providerKeyId)
        } else {
            try c.encodeNil(forKey: .providerKeyId)
        }
    }
}

/// Response shape from both `GET` and `PUT /api/v1/settings/active_provider_key`.
///
/// All fields are nullable so the frontend can render an "未设置 active key" state
/// when the backend has no rows or the previously-active row was deleted.
public struct ActiveProviderKeySummary: Codable, Equatable, Sendable, Hashable {
    public var activeProviderKeyId: String?
    public var keyLabel: String?
    public var providerHint: String?
    public var modelName: String?
    public var apiKeyMask: String?     // "****xxxx" or nil

    enum CodingKeys: String, CodingKey {
        case activeProviderKeyId = "active_provider_key_id"
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case modelName = "model_name"
        case apiKeyMask = "api_key_mask"
    }

    public init(
        activeProviderKeyId: String? = nil,
        keyLabel: String? = nil,
        providerHint: String? = nil,
        modelName: String? = nil,
        apiKeyMask: String? = nil
    ) {
        self.activeProviderKeyId = activeProviderKeyId
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.modelName = modelName
        self.apiKeyMask = apiKeyMask
    }
}
