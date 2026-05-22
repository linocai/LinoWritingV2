import Foundation

public struct Character: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public var bookId: String
    public var name: String
    public var role: String?
    public var frozenFields: [String: JSONValue]
    public var liveFields: [String: JSONValue]
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
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
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CharacterCreateRequest: Codable, Sendable {
    public var name: String
    public var role: String?
    public var frozenFields: [String: JSONValue]?
    public var liveFields: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
    }

    public init(
        name: String,
        role: String? = nil,
        frozenFields: [String: JSONValue]? = nil,
        liveFields: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
    }
}

public struct CharacterPatchRequest: Codable, Sendable {
    public var name: String?
    public var role: String?
    public var frozenFields: [String: JSONValue]?
    public var liveFields: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, role
        case frozenFields = "frozen_fields"
        case liveFields = "live_fields"
    }

    public init(
        name: String? = nil,
        role: String? = nil,
        frozenFields: [String: JSONValue]? = nil,
        liveFields: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.role = role
        self.frozenFields = frozenFields
        self.liveFields = liveFields
    }
}
