import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · reading-page themes.
///
/// Three reading themes (日间 / 护眼 / 夜间) with the handoff's exact colors
/// (§Design Tokens · 阅读页三主题). The reader tints the whole window/screen
/// shell, not just the text column.
///
/// v1.2.0 (GG, P1): un-gated from `#if os(macOS)` — pure enum + `Color` /
/// `CGFloat` ladder, platform-neutral. The iOS reader (P5, `.fullScreenCover`
/// + justified `UITextView`) reuses these color tables + font-size ladder.
enum ReadingTheme: String, CaseIterable, Identifiable, Sendable {
    case day
    case sepia
    case night

    var id: String { rawValue }

    /// Title shown on the theme swatch tooltip.
    var label: String {
        switch self {
        case .day:   return "日间"
        case .sepia: return "护眼"
        case .night: return "夜间"
        }
    }

    /// Page background (整窗壳层背景也用它).
    var background: Color {
        switch self {
        case .day:   return LWColor.hex(0xFBFAF7)
        case .sepia: return LWColor.hex(0xF1E3C8)
        case .night: return LWColor.hex(0x1A1B1F)
        }
    }

    /// Primary text.
    var text: Color {
        switch self {
        case .day:   return LWColor.hex(0x26262B)
        case .sepia: return LWColor.hex(0x4A3B27)
        case .night: return LWColor.hex(0xCDCDD2)
        }
    }

    /// Secondary text (book name · word count, etc.).
    var secondary: Color {
        switch self {
        case .day:   return LWColor.hex(0x7C7D86)
        case .sepia: return LWColor.hex(0x9A8568)
        case .night: return LWColor.hex(0x7E7F88)
        }
    }

    /// Accent (chapter kicker / short rule).
    var accent: Color {
        switch self {
        case .day:   return LWColor.hex(0x9A6A3A)
        case .sepia: return LWColor.hex(0xA8742E)
        case .night: return LWColor.hex(0xC0A06A)
        }
    }

    /// Hairline (发丝线) — buttons / rules on the reading page.
    var hairline: Color {
        switch self {
        case .day:   return Color(.sRGB, red: 60/255, green: 55/255, blue: 45/255, opacity: 0.14)
        case .sepia: return Color(.sRGB, red: 120/255, green: 90/255, blue: 50/255, opacity: 0.22)
        case .night: return Color(.sRGB, white: 1, opacity: 0.12)
        }
    }

    /// Chip background (返回工作台 / A− / A+ / 上一章·下一章 卡片底).
    /// Handoff JS `themes[*].chip`.
    var chipBackground: Color {
        switch self {
        case .day:   return Color(.sRGB, red: 120/255, green: 110/255, blue: 90/255, opacity: 0.08)
        case .sepia: return Color(.sRGB, red: 120/255, green: 90/255, blue: 50/255, opacity: 0.10)
        case .night: return Color(.sRGB, white: 1, opacity: 0.06)
        }
    }

    /// Top-bar background (玻璃细条底，叠 blur(30) saturate(1.6)).
    /// Handoff JS `themes[*].barBg`.
    var barBackground: Color {
        switch self {
        case .day:   return Color(.sRGB, red: 251/255, green: 250/255, blue: 247/255, opacity: 0.80)
        case .sepia: return Color(.sRGB, red: 241/255, green: 227/255, blue: 200/255, opacity: 0.82)
        case .night: return Color(.sRGB, red: 26/255, green: 27/255, blue: 31/255, opacity: 0.82)
        }
    }

    /// The fill of the three theme-picker swatches in the top bar. Note these
    /// are the swatch *button* colors (handoff `#fbfaf7 / #f1e3c8 / #1c1d22`),
    /// which for night differs slightly from the page `background` (`#1a1b1f`).
    var swatchFill: Color {
        switch self {
        case .day:   return LWColor.hex(0xFBFAF7)
        case .sepia: return LWColor.hex(0xF1E3C8)
        case .night: return LWColor.hex(0x1C1D22)
        }
    }

    /// Whether this is a dark theme (used to flip chrome / status-bar style).
    var isDark: Bool { self == .night }

    // MARK: - Font size ladder

    /// Body font-size steps: `18 / 19 / 20 / 21 / 23`. A−/A+ move the index.
    static let fontSizeLadder: [CGFloat] = [18, 19, 20, 21, 23]
    /// Default index → 20pt.
    static let defaultFontSizeIndex = 2

    /// Reading body line-height ≈ size × 2.05; SwiftUI `.lineSpacing` is the
    /// *extra* gap, so subtract one line height: `size × (2.05 − 1.0)`.
    static func lineSpacing(for size: CGFloat) -> CGFloat {
        size * 1.05
    }
}
