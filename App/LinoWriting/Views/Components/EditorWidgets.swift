import SwiftUI

/// v1.1.0 (FF) Phase 3 — editor support widgets (styled text area + streaming
/// caret).
///
/// v1.2.0 (GG, P1): **un-gated** from `MacEditorWidgets.swift`'s `#if os(macOS)`
/// and moved into cross-platform `Views/Components/` so the iOS redesign reuses
/// them (the iOS 设定 / 想法 surfaces use `LWTextArea`; the streaming 正文 uses
/// `BlinkingCaret`). Both are platform-neutral SwiftUI (`TextEditor` /
/// `Rectangle` + `.task`), so macOS rendering is unchanged.

// MARK: - Styled TextEditor with placeholder + design chrome

struct LWTextArea: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 78
    var font: Font = .system(size: 14.5)
    var lineSpacing: CGFloat = 4
    var background: Color = LWColor.hex(0xFCFCFE, opacity: 0.8)
    var border: Color = LWColor.hex(0x282D46, opacity: 0.12)
    var borderWidth: CGFloat = 0.5
    var glow: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(LWColor.bodyText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(minHeight: minHeight)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(LWColor.mutedText3.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.top, 13)
                    .allowsHitTesting(false)
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(border, lineWidth: borderWidth)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((glow ?? .clear), lineWidth: glow != nil ? 3 : 0)
                .blur(radius: glow != nil ? 1 : 0)
                .padding(-1)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Blinking caret for streaming draft

struct BlinkingCaret: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(LWColor.accentStop)
            .frame(width: 2, height: 20)
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 530_000_000)
                    visible.toggle()
                }
            }
    }
}

// NOTE: `FlowLayout` (wrapping tag layout) lives in
// `Views/Components/FlowLayout.swift` with the same `FlowLayout(spacing:)`
// signature — reused by both glass widget sets, not redeclared.
