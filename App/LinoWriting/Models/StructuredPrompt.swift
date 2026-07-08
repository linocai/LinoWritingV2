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
    /// v1.5.0 (NN) P2 — 由 `mustHappen` 改名：定性从「验收清单」变「领读注解」，
    /// 帮 Writer 理解本章 Bible 的情节锚点。
    public var plotAnchors: [String]
    public var charactersInvolved: [String]
    public var sceneSetting: String?
    public var narrativePov: NarrativePOV?
    public var targetWordCount: Int?
    /// v1.5.0 (NN) P2 — 新增：优化师生成的本章文风（≤50 字，服务端截断），
    /// 作者 Step2 可编辑，可清空。
    public var chapterStyle: String?
    /// v1.4.0 (MM) P1 — 优化师「连续性/矛盾校对」产出：给作者看的提醒清单
    /// （缺口/矛盾），Writer 不读。`decodeIfPresent` 容旧：无此键时为 `[]`。
    public var continuityAlerts: [String]

    enum CodingKeys: String, CodingKey {
        case plotAnchors = "plot_anchors"
        case charactersInvolved = "characters_involved"
        case sceneSetting = "scene_setting"
        case narrativePov = "narrative_pov"
        case targetWordCount = "target_word_count"
        case chapterStyle = "chapter_style"
        case continuityAlerts = "continuity_alerts"
    }

    public init(
        plotAnchors: [String] = [],
        charactersInvolved: [String] = [],
        sceneSetting: String? = nil,
        narrativePov: NarrativePOV? = nil,
        targetWordCount: Int? = nil,
        chapterStyle: String? = nil,
        continuityAlerts: [String] = []
    ) {
        self.plotAnchors = plotAnchors
        self.charactersInvolved = charactersInvolved
        self.sceneSetting = sceneSetting
        self.narrativePov = narrativePov
        self.targetWordCount = targetWordCount
        self.chapterStyle = chapterStyle
        self.continuityAlerts = continuityAlerts
    }

    /// 自定义 decoder：容忍老章残留键（`must_happen`/`chapter_goal`/
    /// `must_not_happen`/`extra_notes`/`focus_traits` 等）——`CodingKeys` 里
    /// 已不含这些键，解码时天然忽略，无需显式 `extra="allow"` 等价物。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.plotAnchors = try c.decodeIfPresent([String].self, forKey: .plotAnchors) ?? []
        self.charactersInvolved = try c.decodeIfPresent([String].self, forKey: .charactersInvolved) ?? []
        self.sceneSetting = try c.decodeIfPresent(String.self, forKey: .sceneSetting)
        self.narrativePov = try c.decodeIfPresent(NarrativePOV.self, forKey: .narrativePov)
        self.targetWordCount = try c.decodeIfPresent(Int.self, forKey: .targetWordCount)
        self.chapterStyle = try c.decodeIfPresent(String.self, forKey: .chapterStyle)
        self.continuityAlerts = try c.decodeIfPresent([String].self, forKey: .continuityAlerts) ?? []
    }
}
