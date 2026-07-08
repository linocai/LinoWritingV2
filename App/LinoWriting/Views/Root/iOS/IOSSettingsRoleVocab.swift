#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — Chinese role vocabulary for the iOS 设置 sheet (模型与密钥 /
/// 人格编辑 / 调用日志).
///
/// The macOS sections use `MacRoleVocab` (which is `#if os(macOS)`-gated). The
/// content is identical — the editorial Chinese names the handoff 设置 screen
/// wants (优化师 / Writer / 档案员), not the shared `AgentRole.displayName`
/// English values used elsewhere. Kept as a separate iOS file so neither
/// platform's role-vocab leaks into the other's compile unit and the shared
/// enum stays untouched.
///
///   - `expander`  → 优化师
///   - `writer`    → Writer
///   - `extractor` → 档案员
enum IOSRoleVocab {

    /// Display label for a known `AgentRole`.
    static func label(_ role: AgentRole) -> String {
        switch role {
        case .expander: return "优化师"
        case .writer: return "Writer"
        case .extractor: return "档案员"
        }
    }

    /// Display label from a raw backend `agent_name` string (logs use raw
    /// strings, incl. `admin_reset`). Matches the handoff `agentLabel` map.
    static func label(rawAgentName: String) -> String {
        switch rawAgentName {
        case "expander": return "优化师"
        case "writer": return "Writer"
        case "extractor": return "档案员"
        case "admin_reset": return "强制重置"
        default: return rawAgentName
        }
    }

    /// One-line responsibility blurb for the persona cards.
    /// v1.4.0 (MM) P3 — 优化师降职为结构员+校对员（删 `chapter_directive`）；
    /// Writer 改为直接依据作者本章剧情（Bible）写作，字数落区间。
    /// v1.5.0 (NN) P2 — 优化师终极精简为「框架员+选角员+领读员」，desc 对齐。
    static func desc(_ role: AgentRole) -> String {
        switch role {
        case .expander: return "搭框架（场景/视角/字数/锚点）＋选角＋定本章文风＋提醒连续性（不发明情节）"
        case .writer: return "依据你写的本章剧情（Bible）＋ 上下文包写正文，字数落区间"
        case .extractor: return "把本章实际发生的事，回写进人物卡与时间线"
        }
    }

    /// Stable display order (优化师 → Writer → 档案员), matching the handoff
    /// `activeKeyRows` / `personaCards` order.
    static let displayOrder: [AgentRole] = [.expander, .writer, .extractor]
}
#endif
