#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 5 — Chinese role vocabulary shared by the 模型与密钥 /
/// 人格编辑 / 调用日志 sections.
///
/// The shared `AgentRole.displayName` returns English (Writer / Extractor /
/// Expander) and is used elsewhere; the handoff 设置 screen wants the editorial
/// Chinese names (优化师 / Writer / 档案员). We keep that mapping local so the
/// shared enum stays untouched.
///
///   - `expander`  → 优化师
///   - `writer`    → Writer
///   - `extractor` → 档案员
enum MacRoleVocab {

    /// Display label for a known `AgentRole`.
    static func label(_ role: AgentRole) -> String {
        switch role {
        case .expander: return "优化师"
        case .writer: return "Writer"
        case .extractor: return "档案员"
        }
    }

    /// Display label from a raw backend `agent_name` string (logs use raw
    /// strings, incl. `admin_reset`).
    static func label(rawAgentName: String) -> String {
        switch rawAgentName {
        case "expander": return "优化师"
        case "writer": return "Writer"
        case "extractor": return "档案员"
        case "admin_reset": return "强制重置"
        default: return rawAgentName
        }
    }

    /// One-line responsibility blurb for the persona cards (handoff `roleDesc`).
    static func desc(_ role: AgentRole) -> String {
        switch role {
        case .expander: return "把已完成章梗概 ＋ 记忆 ＋ 你写的本章剧情，磨成 200–300 字「本章创作指令」"
        case .writer: return "依据指令与上下文包，写出 2500–3000 字正文"
        case .extractor: return "把本章实际发生的事，回写进人物卡与时间线"
        }
    }

    /// Stable display order used across the three sections (优化师→Writer→档案员).
    static let displayOrder: [AgentRole] = [.expander, .writer, .extractor]
}
#endif
