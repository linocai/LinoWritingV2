#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) — Liquid Glass theme layer · metrics.
///
/// Corner radii / button heights / spacing / shadows from handoff
/// §Design Tokens (圆角 / 间距 / 阴影). macOS-only.
enum LWMetrics {

    // MARK: - Corner radii (圆角)

    /// Card / panel corner radius (token 13–16 → 14).
    static let cardRadius: CGFloat = 14
    /// Inputs / buttons / tags corner radius (token 8–11 → 10).
    static let controlRadius: CGFloat = 10
    /// Capsule (token 999).
    static let capsuleRadius: CGFloat = 999
    /// Window corner radius (token 15).
    static let windowRadius: CGFloat = 15

    // MARK: - Button heights (按钮高)

    /// Primary action button height (token 38–40 → 40).
    static let primaryButtonHeight: CGFloat = 40
    /// Toolbar icon button (token 34).
    static let toolbarButtonHeight: CGFloat = 34
    /// Small tag / chip height (token 28–30 → 28).
    static let smallTagHeight: CGFloat = 28

    // MARK: - Layout widths (三栏)

    /// Left chapter sidebar width (~258).
    static let sidebarWidth: CGFloat = 258
    /// Right panel width (~326).
    static let rightPanelWidth: CGFloat = 326
    /// Centered content max width (editor flow / bookshelf container).
    static let contentMaxWidth: CGFloat = 720
    /// Bookshelf container max width (~1080).
    static let shelfMaxWidth: CGFloat = 1080

    // MARK: - Window sizing

    static let windowMinWidth: CGFloat = 1080
    static let windowMinHeight: CGFloat = 720
    static let windowDefaultWidth: CGFloat = 1280
    static let windowDefaultHeight: CGFloat = 840

    // MARK: - Stroke / hairline

    /// 0.5px panel/card hairline color: `rgba(40,45,70,0.10)`.
    static let hairline = Color(.sRGB, red: 40/255, green: 45/255, blue: 70/255, opacity: 0.10)
    /// Lighter hairline used on sidebars / separators: `rgba(40,45,70,0.08)`.
    static let hairlineLight = Color(.sRGB, red: 40/255, green: 45/255, blue: 70/255, opacity: 0.08)
    /// Top inset highlight: `inset 0 1px 0 rgba(255,255,255,0.7)`.
    static let topHighlight = Color.white.opacity(0.7)
    static let hairlineWidth: CGFloat = 0.5

    // MARK: - Shadows (阴影)

    /// Primary button glow `0 8px 20px -8px rgba(74,99,240,0.8)` approximated
    /// in SwiftUI's (color, radius, x, y) model.
    enum PrimaryShadow {
        static let color = LWColor.accentStop.opacity(0.5)
        static let radius: CGFloat = 10
        static let y: CGFloat = 6
    }

    /// Card light shadow `0 12px 28px -22px rgba(20,28,60,0.4)`.
    enum CardShadow {
        static let color = Color(.sRGB, red: 20/255, green: 28/255, blue: 60/255, opacity: 0.4)
        static let radius: CGFloat = 14
        static let y: CGFloat = 8
    }
}
#endif
