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

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case characterId = "character_id"
        case chapterId = "chapter_id"
        case chapterIndex = "chapter_index"
        case eventType = "event_type"
        case eventText = "event_text"
        case createdAt = "created_at"
    }
}
