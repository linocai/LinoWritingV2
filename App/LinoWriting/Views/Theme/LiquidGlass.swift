#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · glass material modifiers.
///
/// macOS 26 native `.glassEffect(_:in:)` is the base material; on top of it we
/// layer the handoff's three signature traits so the result reads as the
/// design's "液态玻璃" rather than plain system glass:
///   1. **半透明** — `.glassEffect` (translucent, refracts the desktop behind).
///   2. **0.5px 细描边** — `rgba(40,45,70,0.10)` hairline (`LWMetrics.hairline`).
///   3. **顶部高光** — `inset 0 1px 0 rgba(255,255,255,0.7)`, drawn as a 1px
///      top-edge highlight line inside the clip shape.
///
/// deploymentTarget is macOS 26, so `.glassEffect` is unconditionally
/// available — no `if #available` tier. A `.regularMaterial` fallback path is
/// kept behind a flag only for defensive reuse, but this version ships on 26.
///
/// Use `GlassEffectContainer` (re-exported convenience `LWGlassContainer`) to
/// wrap adjacent glass elements so macOS 26 merges their morph/refraction.
///
/// macOS-only.

// MARK: - Top inset highlight overlay

/// The `inset 0 1px 0 rgba(255,255,255,0.7)` highlight, clipped to the panel
/// shape. Drawn as a thin gradient strip hugging the top edge.
private struct TopHighlightOverlay: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: 0.5)
            .stroke(
                LinearGradient(
                    colors: [LWMetrics.topHighlight, LWMetrics.topHighlight.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Core glass modifier

private struct LWGlassModifier: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat
    var strokeColor: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                // Subtle tint plate under the glass to hit the design's exact
                // panel/sidebar/toolbar luminance (glass alone is neutral).
                if let tint {
                    shape.fill(tint)
                }
            }
            .glassEffect(.regular, in: shape)
            .overlay(TopHighlightOverlay(cornerRadius: cornerRadius))
            .overlay(
                shape
                    .inset(by: 0.25)
                    .stroke(strokeColor, lineWidth: LWMetrics.hairlineWidth)
                    .allowsHitTesting(false)
            )
    }
}

extension View {

    /// Panel glass — content panels / cards.
    /// Handoff: white `rgba(255,255,255,0.5–0.7)` base; here the tint plate is
    /// a faint white wash, the rest is native glass + highlight + hairline.
    func lwPanel(cornerRadius: CGFloat = LWMetrics.cardRadius) -> some View {
        modifier(LWGlassModifier(
            tint: Color.white.opacity(0.18),
            cornerRadius: cornerRadius,
            strokeColor: LWMetrics.hairline
        ))
    }

    /// Sidebar / right-panel glass — `rgba(244,245,250,0.55)`, slightly
    /// different luminance from the content area.
    func lwSidebar(cornerRadius: CGFloat = 0) -> some View {
        modifier(LWGlassModifier(
            tint: Color(.sRGB, red: 244/255, green: 245/255, blue: 250/255, opacity: 0.55),
            cornerRadius: cornerRadius,
            strokeColor: LWMetrics.hairlineLight
        ))
    }

    /// Title bar / toolbar glass — `rgba(250,251,253,0.7)`.
    /// Pair with `.lwToolbarSeparator()` on the bottom edge.
    func lwToolbar(cornerRadius: CGFloat = 0) -> some View {
        modifier(LWGlassModifier(
            tint: Color(.sRGB, red: 250/255, green: 251/255, blue: 253/255, opacity: 0.7),
            cornerRadius: cornerRadius,
            strokeColor: .clear
        ))
    }

    /// Bottom `0.5px` separator line for the toolbar/title bar.
    func lwBottomSeparator() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(LWMetrics.hairline)
                .frame(height: LWMetrics.hairlineWidth)
        }
    }
}

// MARK: - Glass container

/// Thin re-export so call sites read `LWGlassContainer { ... }` and we keep a
/// single seam if the underlying container API needs adjusting. macOS 26
/// `GlassEffectContainer` merges the morph/refraction of adjacent glass.
struct LWGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}
#endif
