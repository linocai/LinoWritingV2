import Foundation

public struct Book: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var coverColor: String?
    public var worldSetting: String?
    public var chapterCount: Int
    public var characterCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverColor = "cover_color"
        case worldSetting = "world_setting"
        case chapterCount = "chapter_count"
        case characterCount = "character_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastOpenedAt = "last_opened_at"
    }

    public init(
        id: String,
        title: String,
        coverColor: String? = nil,
        worldSetting: String? = nil,
        chapterCount: Int = 0,
        characterCount: Int = 0,
        createdAt: Date,
        updatedAt: Date,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.coverColor = coverColor
        self.worldSetting = worldSetting
        self.chapterCount = chapterCount
        self.characterCount = characterCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct BookCreateRequest: Codable, Sendable {
    public var title: String
    public var coverColor: String?

    enum CodingKeys: String, CodingKey {
        case title
        case coverColor = "cover_color"
    }

    public init(title: String, coverColor: String? = nil) {
        self.title = title
        self.coverColor = coverColor
    }
}

public struct BookPatchRequest: Codable, Sendable {
    public var title: String?
    public var coverColor: String?
    public var worldSetting: String?

    enum CodingKeys: String, CodingKey {
        case title
        case coverColor = "cover_color"
        case worldSetting = "world_setting"
    }

    public init(
        title: String? = nil,
        coverColor: String? = nil,
        worldSetting: String? = nil
    ) {
        self.title = title
        self.coverColor = coverColor
        self.worldSetting = worldSetting
    }
}
