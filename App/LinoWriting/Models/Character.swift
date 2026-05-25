import Foundation

public struct Character: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public var bookId: String
    public var name: String
    public var role: String?
    public var frozenFields: [String: JSONValue]
    public var liveFields: [String: JSONValue]
    /// PROJECT_PLAN §5.L.3 — author-only notes; Writer reads but never
    /// narrates verbatim. Defaults to `[:]` for older payloads (pre-L-1).
    public var authorNotes: [String: JSONValue]
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
        case authorNotes = "author_notes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        bookId: String,
        name: String,
        role: String? = nil,
        frozenFields: [String: JSONValue] = [:],
        liveFields: [String: JSONValue] = [:],
        authorNotes: [String: JSONValue] = [:],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
        self.authorNotes = authorNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decoder mirrors `Chapter.source` fallback pattern (§5.A.6):
    /// tolerate older cached payloads predating §5.L.1 by defaulting
    /// `author_notes` to `[:]` so the UI never crashes on legacy JSON.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.bookId = try c.decode(String.self, forKey: .bookId)
        self.name = try c.decode(String.self, forKey: .name)
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
        self.frozenFields = try c.decodeIfPresent([String: JSONValue].self, forKey: .frozenFields) ?? [:]
        self.liveFields = try c.decodeIfPresent([String: JSONValue].self, forKey: .liveFields) ?? [:]
        self.authorNotes = try c.decodeIfPresent([String: JSONValue].self, forKey: .authorNotes) ?? [:]
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public struct CharacterCreateRequest: Codable, Sendable {
    public var name: String
    public var role: String?
    public var frozenFields: [String: JSONValue]?
    public var liveFields: [String: JSONValue]?
    public var authorNotes: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
        case authorNotes = "author_notes"
    }

    public init(
        name: String,
        role: String? = nil,
        frozenFields: [String: JSONValue]? = nil,
        liveFields: [String: JSONValue]? = nil,
        authorNotes: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
        self.authorNotes = authorNotes
    }
}

public struct CharacterPatchRequest: Codable, Sendable {
    public var name: String?
    public var role: String?
    public var frozenFields: [String: JSONValue]?
    public var liveFields: [String: JSONValue]?
    public var authorNotes: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
        case authorNotes = "author_notes"
    }

    public init(
        name: String? = nil,
        role: String? = nil,
        frozenFields: [String: JSONValue]? = nil,
        liveFields: [String: JSONValue]? = nil,
        authorNotes: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
        self.authorNotes = authorNotes
    }
}
