import SwiftUI
#if os(macOS)
import AppKit
#endif

/// v1.1.0 (FF) Phase 3 — small reusable glass controls (button / chip / label /
/// divider) used across the Liquid Glass workspace (title bar / sidebar /
/// editor / right panel). Pixel-exact transcriptions of the recurring idioms in
/// the handoff (`LinoWriting.dc.html` 工作台).
///
/// v1.2.0 (GG, P1): **un-gated** from `MacWorkspaceControls.swift`'s
/// `#if os(macOS)` and moved into cross-platform `Views/Components/` so the iOS
/// redesign (P2–P6) reuses the same controls. The ONLY platform-sensitive code
/// is the `pointer(_:)` cursor helper — `NSCursor` on macOS, a no-op on iOS
/// (touch has no cursor). Everything else is platform-neutral SwiftUI, so macOS
/// rendering is byte-for-byte unchanged.

// MARK: - Primary accent button (40 high, accent gradient, glow)

struct LWPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = LWMetrics.primaryButtonHeight
    var horizontalPadding: CGFloat = 22
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .background(
                LWColor.accentGradient.opacity(enabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .brightness(hovered && enabled ? 0.04 : 0)
            .shadow(color: LWColor.accentStop.opacity(enabled ? 0.5 : 0), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in hovered = h; pointer(h && enabled) }
    }
}

// MARK: - Soft accent (tinted) pill button — "✦ 优化师 · 生成本章指令"

struct LWAccentTintButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = 38
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(LWColor.accentText)
            .frame(height: height)
            .padding(.horizontal, 18)
            .background(
                LWColor.accentStart.opacity(0.13),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LWColor.accentStart.opacity(0.25), lineWidth: 0.5)
            )
            .brightness(hovered && enabled ? -0.02 : 0)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in hovered = h; pointer(h && enabled) }
    }
}

// MARK: - Danger tint pill — "■ 停止生成"

struct LWDangerTintButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = LWMetrics.primaryButtonHeight
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(LWColor.danger)
            .frame(height: height)
            .padding(.horizontal, 20)
            .background(
                LWColor.danger.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LWColor.danger.opacity(0.3), lineWidth: 0.5)
            )
            .brightness(hovered ? -0.02 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h; pointer(h) }
    }
}

// MARK: - Success gradient button — "✓ 档案员 · 提取入库"

struct LWSuccessButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(height: LWMetrics.primaryButtonHeight)
            .padding(.horizontal, 22)
            .background(
                LWColor.successGradient.opacity(enabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .brightness(hovered && enabled ? 0.04 : 0)
            .shadow(color: LWColor.success.opacity(enabled ? 0.5 : 0), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in hovered = h; pointer(h && enabled) }
    }
}

// MARK: - Bordered neutral pill — "↻ 重新提取" / "↺ 重新打开编辑" / "导出整本…"

struct LWBorderedButton: View {
    let title: String
    var systemImage: String? = nil
    var foreground: Color = LWColor.secondaryText2
    var height: CGFloat = LWMetrics.primaryButtonHeight
    var fullWidth: Bool = false
    /// v1.4.0 (MM) P4 — the "修订" button stays *visible* while a write/revise
    /// job is running (draft_ready 态可见不隐藏) but must "置灰" (disabled +
    /// dimmed), mirroring `LWSuccessButton`'s `enabled` shape.
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                }
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, fullWidth ? 0 : 16)
            .background(
                Color.white.opacity(hovered ? 0.75 : 0.6),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5)
            )
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in hovered = h; pointer(h && enabled) }
    }
}

// MARK: - Square toolbar icon button (34×34)

struct LWIconButton: View {
    let systemName: String
    var foreground: Color = LWColor.secondaryText2
    var size: CGFloat = LWMetrics.toolbarButtonHeight
    var fontSize: CGFloat = 14
    var help: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(
                    Color.white.opacity(hovered ? 0.75 : 0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { h in hovered = h; pointer(h) }
    }
}

// MARK: - Section label (small uppercase tracked caption) — "本章目标" etc.

struct LWSectionLabel: View {
    let text: String
    var color: Color = LWColor.mutedText3

    init(_ text: String, color: Color = LWColor.mutedText3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.12 * 11)
            .foregroundStyle(color)
    }
}

// MARK: - Pointer cursor helper

/// Push / pop the pointing-hand cursor on macOS hover. On iOS there is no
/// cursor (touch), so this is a no-op — the `.onHover` modifier still compiles
/// and is simply inert for touch input. Keeping the seam here means the button
/// call sites stay identical across platforms.
@MainActor
func pointer(_ inside: Bool) {
    #if os(macOS)
    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    #endif
}
