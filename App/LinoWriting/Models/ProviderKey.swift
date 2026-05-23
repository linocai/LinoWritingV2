import Foundation

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
public struct ProviderKey: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public var keyLabel: String
    public var providerHint: String?
    public var baseUrl: String
    public var apiKey: String          // masked: "****xxxx"
    public var modelName: String
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
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
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Body for `POST /api/v1/provider_keys`. `apiKey` here is the FULL key —
/// the backend will store it and only return the masked form on subsequent reads.
public struct ProviderKeyCreate: Codable, Sendable {
    public var keyLabel: String
    public var providerHint: String?
    public var baseUrl: String
    public var apiKey: String
    public var modelName: String

    enum CodingKeys: String, CodingKey {
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
    }

    public init(
        keyLabel: String,
        providerHint: String? = nil,
        baseUrl: String,
        apiKey: String,
        modelName: String
    ) {
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
    }
}

/// Body for `PATCH /api/v1/provider_keys/{id}`. Every field is optional —
/// fields left nil are not modified server-side.
///
/// Note: `apiKey` is sent only when the user re-enters a full key. The plan
/// (§5.E.3 / §5.E.6) is that leaving the SecureField blank means "keep the
/// existing key"; an empty string would be rejected with 422 by the backend.
public struct ProviderKeyUpdate: Codable, Sendable {
    public var keyLabel: String?
    public var providerHint: String?
    public var baseUrl: String?
    public var apiKey: String?
    public var modelName: String?

    enum CodingKeys: String, CodingKey {
        case keyLabel = "key_label"
        case providerHint = "provider_hint"
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
    }

    public init(
        keyLabel: String? = nil,
        providerHint: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil,
        modelName: String? = nil
    ) {
        self.keyLabel = keyLabel
        self.providerHint = providerHint
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelName = modelName
    }
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
