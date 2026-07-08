import Foundation

public enum NarrativePOV: String, Codable, CaseIterable, Sendable {
    case firstPerson = "first_person"
    case thirdPersonLimited = "third_person_limited"
    case thirdPersonOmniscient = "third_person_omniscient"

    public var label: String {
        switch self {
        case .firstPerson: return "第一人称"
        case .thirdPersonLimited: return "第三人称（限知）"
        case .thirdPersonOmniscient: return "第三人称（全知）"
        }
    }
}

public struct StructuredPrompt: Codable, Equatable, Sendable, Hashable {
    public var chapterGoal: String
    public var mustHappen: [String]
    public var mustNotHappen: [String]
    public var charactersInvolved: [String]
    public var sceneSetting: String?
    public var narrativePov: NarrativePOV?
    public var targetWordCount: Int?
    public var extraNotes: String?
    /// PROJECT_PLAN §5.L.3 / §5.L.5 — 0-2 trait names that the Writer should
    /// preferentially emerge this chapter. Empty for older payloads.
    public var focusTraits: [String]
    /// v1.4.0 (MM) P1 — 优化师「连续性/矛盾校对」产出：给作者看的提醒清单
    /// （缺口/矛盾），Writer 不读。`decodeIfPresent` 容旧：无此键时为 `[]`。
    public var continuityAlerts: [String]

    enum CodingKeys: String, CodingKey {
        case chapterGoal = "chapter_goal"
        case mustHappen = "must_happen"
        case mustNotHappen = "must_not_happen"
        case charactersInvolved = "characters_involved"
        case sceneSetting = "scene_setting"
        case narrativePov = "narrative_pov"
        case targetWordCount = "target_word_count"
        case extraNotes = "extra_notes"
        case focusTraits = "focus_traits"
        case continuityAlerts = "continuity_alerts"
    }

    public init(
        chapterGoal: String = "",
        mustHappen: [String] = [],
        mustNotHappen: [String] = [],
        charactersInvolved: [String] = [],
        sceneSetting: String? = nil,
        narrativePov: NarrativePOV? = nil,
        targetWordCount: Int? = nil,
        extraNotes: String? = nil,
        focusTraits: [String] = [],
        continuityAlerts: [String] = []
    ) {
        self.chapterGoal = chapterGoal
        self.mustHappen = mustHappen
        self.mustNotHappen = mustNotHappen
        self.charactersInvolved = charactersInvolved
        self.sceneSetting = sceneSetting
        self.narrativePov = narrativePov
        self.targetWordCount = targetWordCount
        self.extraNotes = extraNotes
        self.focusTraits = focusTraits
        self.continuityAlerts = continuityAlerts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chapterGoal = try c.decodeIfPresent(String.self, forKey: .chapterGoal) ?? ""
        self.mustHappen = try c.decodeIfPresent([String].self, forKey: .mustHappen) ?? []
        self.mustNotHappen = try c.decodeIfPresent([String].self, forKey: .mustNotHappen) ?? []
        self.charactersInvolved = try c.decodeIfPresent([String].self, forKey: .charactersInvolved) ?? []
        self.sceneSetting = try c.decodeIfPresent(String.self, forKey: .sceneSetting)
        self.narrativePov = try c.decodeIfPresent(NarrativePOV.self, forKey: .narrativePov)
        self.targetWordCount = try c.decodeIfPresent(Int.self, forKey: .targetWordCount)
        self.extraNotes = try c.decodeIfPresent(String.self, forKey: .extraNotes)
        self.focusTraits = try c.decodeIfPresent([String].self, forKey: .focusTraits) ?? []
        self.continuityAlerts = try c.decodeIfPresent([String].self, forKey: .continuityAlerts) ?? []
    }
}
