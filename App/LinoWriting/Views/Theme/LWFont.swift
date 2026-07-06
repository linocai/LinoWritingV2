import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · fonts.
///
/// - **Serif (宋体)**: system `Songti SC` (ships with macOS *and* iOS, NOT
///   packaged). Titles / book names / chapter names / reading body / Step1
///   本章剧情 editor — the "literary" surfaces. Handoff used Noto Serif SC; `Songti SC`
///   is the close system equivalent (present on macOS at
///   `/System/Library/Fonts/Supplemental/Songti.ttc`, and on iOS as a built-in
///   `Font.custom("Songti SC", …)` family).
/// - **UI**: SwiftUI default (San Francisco / PingFang SC) — leave as-is.
/// - **Mono**: SF Mono via `.system(design: .monospaced)` for backend URL /
///   API_TOKEN / token counts.
///
/// v1.2.0 (GG, P1): un-gated from `#if os(macOS)` — `Font.custom` / system
/// fonts are platform-neutral, shared with the iOS redesign.
enum LWFont {

    /// Serif (Songti SC) at an arbitrary point size. Use for headings, book /
    /// chapter names, reading body, Step1 本章剧情 editor.
    static func songti(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Songti SC", size: size).weight(weight)
    }

    /// Serif tied to a Dynamic Type text style (scales with the relative size
    /// of `style`). Prefer the explicit-size overload for the reading page
    /// where the size ladder is exact.
    static func songti(relativeTo style: Font.TextStyle, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Songti SC", size: size, relativeTo: style).weight(weight)
    }

    /// Monospaced (SF Mono) for URLs / keys / counts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Convenience: the literal PostScript family name, for callers that need
    /// to construct an `NSFont` (macOS) / `UIFont` (iOS) / attributed-string
    /// font directly (e.g. a justified reading body via paragraph attributes —
    /// the P5 iOS `UITextView` reader uses this).
    static let songtiFamily = "Songti SC"
}
