import Foundation

public enum ChapterStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case promptReady = "prompt_ready"
    case writing
    case draftReady = "draft_ready"
    case finalized

    public var label: String {
        switch self {
        case .draft: return "草稿"
        case .promptReady: return "提示完成"
        case .writing: return "写作中"
        case .draftReady: return "正文完成"
        case .finalized: return "已完成"
        }
    }
}

public struct ChapterSummary: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let index: Int
    public var title: String?
    public var status: ChapterStatus
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, index, title, status
        case updatedAt = "updated_at"
    }
}

public struct Chapter: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let bookId: String
    public let index: Int
    public var title: String?
    public var userPrompt: String?
    public var structuredPrompt: StructuredPrompt?
    public var draftText: String?
    public var summary: String?
    public var status: ChapterStatus
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case index, title
        case userPrompt = "user_prompt"
        case structuredPrompt = "structured_prompt"
        case draftText = "draft_text"
        case summary, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        bookId: String,
        index: Int,
        title: String? = nil,
        userPrompt: String? = nil,
        structuredPrompt: StructuredPrompt? = nil,
        draftText: String? = nil,
        summary: String? = nil,
        status: ChapterStatus,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.index = index
        self.title = title
        self.userPrompt = userPrompt
        self.structuredPrompt = structuredPrompt
        self.draftText = draftText
        self.summary = summary
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var summaryShape: ChapterSummary {
        ChapterSummary(id: id, index: index, title: title, status: status, updatedAt: updatedAt)
    }
}

public struct ChapterCreateRequest: Codable, Sendable {
    public var userPrompt: String?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case userPrompt = "user_prompt"
        case title
    }

    public init(userPrompt: String? = nil, title: String? = nil) {
        self.userPrompt = userPrompt
        self.title = title
    }
}

public struct ChapterPatchRequest: Codable, Sendable {
    public var title: String?
    public var userPrompt: String?
    public var structuredPrompt: StructuredPrompt?
    public var draftText: String?

    enum CodingKeys: String, CodingKey {
        case title
        case userPrompt = "user_prompt"
        case structuredPrompt = "structured_prompt"
        case draftText = "draft_text"
    }

    public init(
        title: String? = nil,
        userPrompt: String? = nil,
        structuredPrompt: StructuredPrompt? = nil,
        draftText: String? = nil
    ) {
        self.title = title
        self.userPrompt = userPrompt
        self.structuredPrompt = structuredPrompt
        self.draftText = draftText
    }
}

public struct FinalizeResult: Codable, Sendable {
    public let chapter: Chapter
    public let updatedCharacterIds: [String]
    public let addedEventIds: [String]

    enum CodingKeys: String, CodingKey {
        case chapter
        case updatedCharacterIds = "updated_character_ids"
        case addedEventIds = "added_event_ids"
    }
}
