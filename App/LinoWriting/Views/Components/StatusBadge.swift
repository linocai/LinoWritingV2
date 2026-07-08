import SwiftUI

/// Chapter status badge.
///
/// v1.1.0 (FF): colors switched to the handoff §Design Tokens (章节状态色)
/// exact values — each status has a distinct text color over a tinted
/// capsule. The label text comes from `ChapterStatus.label` (now the
/// design-spec wording 构思中/结构就绪/写作中/草稿就绪/已完成).
///
/// Self-contained (no dependency on the macOS-only `LWColor` theme layer) so
/// it renders identically on iOS — the redesign's status palette is shared,
/// not a macOS-only degrade.
public struct StatusBadge: View {
    public let status: ChapterStatus
    /// v1.4.0 (MM) P4 — optional label swap while keeping `status`'s color
    /// palette (e.g. "修订中" over the `.writing` blue, during the two-pass
    /// compression sub-phase, which server-side is still `status=="writing"`
    /// — there is no separate persisted `ChapterStatus` case for it).
    public var overrideLabel: String?

    public init(_ status: ChapterStatus, overrideLabel: String? = nil) {
        self.status = status
        self.overrideLabel = overrideLabel
    }

    public var body: some View {
        // PROJECT_PLAN §5.K.4 (字体段): `.contentTransition(.numericText())` lets
        // the label morph between states (e.g. 写作中 → 草稿就绪) rather than
        // hard-snap. The outer `.animation(.smooth, value: status)` is what
        // actually drives the transition — without it, contentTransition is inert.
        Text(overrideLabel ?? status.label)
            .font(.caption2.weight(.semibold))
            .contentTransition(.numericText())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(palette.background, in: Capsule())
            .foregroundStyle(palette.text)
            .animation(.smooth(duration: 0.3), value: status)
            // v1.4.0 (MM) P4 — the "写作中"→"修订中" label swap happens with
            // `status` unchanged (both are `.writing` server-side), so the
            // transition needs its own trigger keyed on `overrideLabel` too.
            .animation(.smooth(duration: 0.3), value: overrideLabel)
    }

    private var palette: (text: Color, background: Color) {
        switch status {
        case .draft:
            // #9499AD on rgba(148,153,173,0.14)
            return (Self.rgb(0x9499AD), Self.rgba(148, 153, 173, 0.14))
        case .promptReady:
            // #B8731F on rgba(214,150,40,0.16)
            return (Self.rgb(0xB8731F), Self.rgba(214, 150, 40, 0.16))
        case .writing:
            // #4A63F0 on rgba(74,99,240,0.16)
            return (Self.rgb(0x4A63F0), Self.rgba(74, 99, 240, 0.16))
        case .draftReady:
            // #1F7A8C on rgba(31,140,150,0.16)
            return (Self.rgb(0x1F7A8C), Self.rgba(31, 140, 150, 0.16))
        case .finalized:
            // #2F8F5B on rgba(47,143,91,0.16)
            return (Self.rgb(0x2F8F5B), Self.rgba(47, 143, 91, 0.16))
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1
        )
    }

    private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
}

#Preview {
    HStack {
        ForEach(ChapterStatus.allCases, id: \.self) { StatusBadge($0) }
    }
    .padding()
}
