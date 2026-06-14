#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · colors.
///
/// Every value here is a **pixel-exact** transcription of the handoff
/// §Design Tokens (`design_handoff_lino_writing_macos/README.md`). Hex are
/// written as `Color(red:green:blue:)` literals (sRGB 0–1); rgba tokens with
/// alpha use `.opacity(_:)`. Do not invent colors — the handoff says
/// "颜色不要新造；以本文档值为准".
///
/// macOS-only (the redesign is macOS-first; iOS keeps its existing palette).
enum LWColor {

    // MARK: - Hex helper

    /// Build an sRGB color from a 24-bit hex literal (e.g. `0x5B7CFF`).
    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    // MARK: - Accent (主色)

    /// `#5B7CFF` — accent gradient start.
    static let accentStart = hex(0x5B7CFF)
    /// `#4A63F0` — accent gradient stop / accent text.
    static let accentStop = hex(0x4A63F0)
    /// `#4A63F0` — links, selected-state text.
    static let accentText = hex(0x4A63F0)
    /// `#2F3A8C` — selected row / tag text (accent deep).
    static let accentDeep = hex(0x2F3A8C)

    /// `#5B7CFF → #4A63F0` at 180° (top → bottom). Primary buttons / actions.
    static let accentGradient = LinearGradient(
        colors: [accentStart, accentStop],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Logo (角标 / 头像)

    /// `#6A7BFF → #9A6BFF` at 140°. Avatar / badge.
    static let logoGradient = LinearGradient(
        colors: [hex(0x6A7BFF), hex(0x9A6BFF)],
        // 140° in CSS ≈ from top-left toward bottom-right.
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Text (文字)

    /// `#20232E` — H1 / large titles.
    static let titleText = hex(0x20232E)
    /// `#2C2F3A` — primary body text.
    static let bodyText = hex(0x2C2F3A)
    /// `#50535F` — secondary / explanatory.
    static let secondaryText = hex(0x50535F)
    /// `#5A5D6A` — secondary (alt, demoted content).
    static let secondaryText2 = hex(0x5A5D6A)
    /// `#7C7F8E` — muted (labels).
    static let mutedText = hex(0x7C7F8E)
    /// `#8B90A6` — muted (placeholder).
    static let mutedText2 = hex(0x8B90A6)
    /// `#9499AD` — muted (meta info).
    static let mutedText3 = hex(0x9499AD)

    // MARK: - Semantic (语义色)

    /// `#2F8F5B` — success / done / extract.
    static let success = hex(0x2F8F5B)
    /// `#36B06A` — success gradient end.
    static let successEnd = hex(0x36B06A)
    /// `#2F8F5B → #36B06A`.
    static let successGradient = LinearGradient(
        colors: [success, successEnd],
        startPoint: .top,
        endPoint: .bottom
    )
    /// `#C0564F` — danger / delete / error.
    static let danger = hex(0xC0564F)
    /// `#B0683A` — warning / reset / edited.
    static let warning = hex(0xB0683A)
    /// `#7D4FB0` — author-note purple text.
    static let authorNote = hex(0x7D4FB0)
    /// `rgba(154,107,224,0.08)` — author-note block background.
    static let authorNoteBg = Color(.sRGB, red: 154/255, green: 107/255, blue: 224/255, opacity: 0.08)
    /// `#FF9F0A` — field-level red dot (unread highlight).
    static let fieldDot = hex(0xFF9F0A)

    // MARK: - Cover gradients (书封面色, 六色)

    /// Six author-facing cover swatch names → display gradient.
    /// `cover_color` is stored as one of these strings; the backend keeps it
    /// opaque (no enum). Unknown / nil falls back to indigo.
    ///
    /// Pixel-exact transcription of the handoff `coverGradients` map
    /// (`LinoWriting.dc.html`): three colour stops at CSS `150°`. `150°` in CSS
    /// points down-and-right, so SwiftUI `.topLeading → .bottomTrailing` is the
    /// closest mapping (same convention used by `logoGradient`'s 140°). Stop
    /// offsets (0/55–60/100 %) are carried via `.init(color:location:)`.
    static func coverGradient(_ name: String?) -> LinearGradient {
        switch name {
        case "indigo": return gradient((0x4453C9, 0), (0x6A4BD0, 0.60), (0x8C5BE0, 1))
        case "rose":   return gradient((0xD65B8A, 0), (0xE0717A, 0.55), (0xF0A06B, 1))
        case "green":  return gradient((0x2F8F6B, 0), (0x4AA37A, 0.60), (0x7BC08A, 1))
        case "amber":  return gradient((0xD99A2B, 0), (0xE0B14A, 0.55), (0xC97A3A, 1))
        case "teal":   return gradient((0x1F8A8C, 0), (0x3AA3A0, 0.55), (0x6BC0B0, 1))
        case "slate":  return gradient((0x4A5566, 0), (0x5E6B7E, 0.55), (0x7E8AA0, 1))
        default:       return gradient((0x4453C9, 0), (0x6A4BD0, 0.60), (0x8C5BE0, 1))
        }
    }

    /// Ordered swatch list for the "new book" / 设定 cover picker.
    static let coverSwatchNames = ["indigo", "rose", "green", "amber", "teal", "slate"]

    private static func gradient(_ stops: (UInt32, Double)...) -> LinearGradient {
        LinearGradient(
            stops: stops.map { Gradient.Stop(color: hex($0.0), location: $0.1) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
#endif
