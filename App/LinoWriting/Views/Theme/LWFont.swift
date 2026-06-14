#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · fonts.
///
/// - **Serif (宋体)**: system `Songti SC` (ships with macOS, NOT packaged).
///   Titles / book names / chapter names / reading body / outline editor —
///   the "literary" surfaces. Handoff used Noto Serif SC; `Songti SC` is the
///   close system equivalent (verified present at
///   `/System/Library/Fonts/Supplemental/Songti.ttc`).
/// - **UI**: SwiftUI default (San Francisco / PingFang SC) — leave as-is.
/// - **Mono**: SF Mono via `.system(design: .monospaced)` for backend URL /
///   API_TOKEN / token counts.
///
/// macOS-only.
enum LWFont {

    /// Serif (Songti SC) at an arbitrary point size. Use for headings, book /
    /// chapter names, reading body, outline editor.
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
    /// to construct an `NSFont` / attributed-string font directly (e.g. a
    /// justified reading body via paragraph attributes).
    static let songtiFamily = "Songti SC"
}
#endif
