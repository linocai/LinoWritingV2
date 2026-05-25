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

/// Provenance marker — whether the chapter body came from the Agent (default)
/// or was imported by the user via the §5.A import flow.
///
/// Backend ships this on every `chapter_read` / `chapter_summary` payload
/// (PROJECT_PLAN §5.A.3). Decoding falls back to `.agent` for any legacy
/// payload that omits the field (Swift's `Codable` default-value semantics
/// kick in through the `init(from:)` override below).
public enum ChapterSource: String, Codable, Sendable {
    case agent
    case imported
}

public struct ChapterSummary: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let index: Int
    public var title: String?
    public var status: ChapterStatus
    public var source: ChapterSource
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, index, title, status, source
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        index: Int,
        title: String? = nil,
        status: ChapterStatus,
        source: ChapterSource = .agent,
        updatedAt: Date
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.status = status
        self.source = source
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.index = try c.decode(Int.self, forKey: .index)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.status = try c.decode(ChapterStatus.self, forKey: .status)
        // PROJECT_PLAN §5.A.6: tolerate older backends / cached payloads that
        // predate the `source` column — default to `.agent` so the UI never
        // shows a phantom "imported" badge.
        self.source = try c.decodeIfPresent(ChapterSource.self, forKey: .source) ?? .agent
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
    public var source: ChapterSource
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case index, title
        case userPrompt = "user_prompt"
        case structuredPrompt = "structured_prompt"
        case draftText = "draft_text"
        case summary, status, source
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
        source: ChapterSource = .agent,
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
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.bookId = try c.decode(String.self, forKey: .bookId)
        self.index = try c.decode(Int.self, forKey: .index)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.userPrompt = try c.decodeIfPresent(String.self, forKey: .userPrompt)
        self.structuredPrompt = try c.decodeIfPresent(StructuredPrompt.self, forKey: .structuredPrompt)
        self.draftText = try c.decodeIfPresent(String.self, forKey: .draftText)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.status = try c.decode(ChapterStatus.self, forKey: .status)
        // PROJECT_PLAN §5.A.6: legacy payload fallback — see `ChapterSummary`.
        self.source = try c.decodeIfPresent(ChapterSource.self, forKey: .source) ?? .agent
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public var summaryShape: ChapterSummary {
        ChapterSummary(
            id: id,
            index: index,
            title: title,
            status: status,
            source: source,
            updatedAt: updatedAt
        )
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

/// Request body for `POST /api/v1/chapters/{id}/import` (PROJECT_PLAN §5.A.4).
///
/// `draftText` is required. `title` and `summary` overwrite existing values
/// when present (left as `nil` to keep current values). `runExtractor`
/// defaults to `true` — the import sheet exposes this as a "导入后让 Agent
/// 提取角色更新和时间线" toggle.
public struct ChapterImportRequest: Codable, Sendable {
    public var draftText: String
    public var title: String?
    public var summary: String?
    public var runExtractor: Bool

    enum CodingKeys: String, CodingKey {
        case draftText = "draft_text"
        case title
        case summary
        case runExtractor = "run_extractor"
    }

    public init(
        draftText: String,
        title: String? = nil,
        summary: String? = nil,
        runExtractor: Bool = true
    ) {
        self.draftText = draftText
        self.title = title
        self.summary = summary
        self.runExtractor = runExtractor
    }
}

/// Request body for `POST /api/v1/chapters/{id}/admin_reset`
/// (PROJECT_PLAN v0.7 §5.P.1 E).
///
/// Used as an escape hatch when a chapter is stuck (SSE crash, server
/// restart mid-stream, etc.). The backend's `AdminResetTarget` Literal
/// only accepts `draft` / `prompt_ready` / `draft_ready` — passing
/// `.writing` or `.finalized` will 422. Front-end callers always pass
/// `.draftReady` (the default) so the user gets back to a state where
/// they can re-finalize or re-write without losing existing text.
public struct ChapterAdminResetRequest: Codable, Sendable {
    public var targetStatus: ChapterStatus

    enum CodingKeys: String, CodingKey {
        case targetStatus = "target_status"
    }

    public init(targetStatus: ChapterStatus = .draftReady) {
        self.targetStatus = targetStatus
    }
}

/// Response envelope from `POST /api/v1/chapters/{id}/import`.
///
/// Mirrors `FinalizeResult` exactly — backend §5.A.4 guarantees the same
/// `{ chapter, updated_character_ids, added_event_ids }` shape so the
/// frontend can treat import as a finalize-equivalent transition (chapter
/// ends in `finalized` status with `source == .imported`).
public struct ChapterImportResponse: Codable, Sendable {
    public let chapter: Chapter
    public let updatedCharacterIds: [String]
    public let addedEventIds: [String]

    enum CodingKeys: String, CodingKey {
        case chapter
        case updatedCharacterIds = "updated_character_ids"
        case addedEventIds = "added_event_ids"
    }
}
