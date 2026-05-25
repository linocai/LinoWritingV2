import Foundation

public enum TimelineEventType: String, Codable, CaseIterable, Sendable {
    case action
    case experience
    case relationChange = "relation_change"
    case secretLearned = "secret_learned"
    case abilityGained = "ability_gained"
    case stateChange = "state_change"

    public var label: String {
        switch self {
        case .action: return "行动"
        case .experience: return "经历"
        case .relationChange: return "关系变化"
        case .secretLearned: return "得知秘密"
        case .abilityGained: return "获得能力"
        case .stateChange: return "状态变化"
        }
    }
}

public struct TimelineEvent: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let bookId: String
    public let characterId: String
    public let chapterId: String
    public let chapterIndex: Int
    public var eventType: TimelineEventType
    public var eventText: String
    public var createdAt: Date
    /// v0.7 §5.C — NULL for Agent-original rows, ISO-stamped on every user
    /// PATCH. The UI renders a "已编辑" marker when this is non-nil.
    public var editedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case characterId = "character_id"
        case chapterId = "chapter_id"
        case chapterIndex = "chapter_index"
        case eventType = "event_type"
        case eventText = "event_text"
        case createdAt = "created_at"
        case editedAt = "edited_at"
    }

    public init(
        id: String,
        bookId: String,
        characterId: String,
        chapterId: String,
        chapterIndex: Int,
        eventType: TimelineEventType,
        eventText: String,
        createdAt: Date,
        editedAt: Date? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.characterId = characterId
        self.chapterId = chapterId
        self.chapterIndex = chapterIndex
        self.eventType = eventType
        self.eventText = eventText
        self.createdAt = createdAt
        self.editedAt = editedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.bookId = try c.decode(String.self, forKey: .bookId)
        self.characterId = try c.decode(String.self, forKey: .characterId)
        self.chapterId = try c.decode(String.self, forKey: .chapterId)
        self.chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        self.eventType = try c.decode(TimelineEventType.self, forKey: .eventType)
        self.eventText = try c.decode(String.self, forKey: .eventText)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Backward-compatible: pre-v0.7 cached payloads have no `edited_at`.
        self.editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
    }
}

/// v0.7 §5.C — body for ``PATCH /api/v1/timeline_events/{id}``. At least one
/// of ``eventText`` / ``eventType`` MUST be non-nil; the backend 422s otherwise.
public struct TimelineEventPatchRequest: Codable, Sendable {
    public var eventText: String?
    public var eventType: TimelineEventType?

    enum CodingKeys: String, CodingKey {
        case eventText = "event_text"
        case eventType = "event_type"
    }

    public init(eventText: String? = nil, eventType: TimelineEventType? = nil) {
        self.eventText = eventText
        self.eventType = eventType
    }
}
