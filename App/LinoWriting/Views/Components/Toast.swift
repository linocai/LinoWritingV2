import SwiftUI

/// Toast notification driven by `ErrorBus`.
///
/// v1.1.0 (FF): restyled to the handoff spec — a **bottom-center dark glass
/// capsule** that auto-dismisses after ~2.6s (was a bottom-trailing
/// `.thinMaterial` card). Behaviour preserved from before:
/// - Non-critical notices auto-dismiss after 2.6 seconds.
/// - Critical (401) notices stick around until the user dismisses them.
///
/// The dark capsule is the same on macOS and iOS (shared look, not a macOS
/// degrade). macOS additionally rides the native glass material; iOS uses a
/// dark material fill — both read as the design's deep-glass pill.
public struct Toast: View {
    @EnvironmentObject private var bus: ErrorBus
    @State private var dismissWorkItem: DispatchWorkItem?

    public init() {}

    public var body: some View {
        // `.animation(.smooth, value:)` at the container level drives the
        // .transition below — without it the move/opacity is a hard snap.
        Group {
            content
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.smooth(duration: 0.25), value: bus.current?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let notice = bus.current {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: notice.isCritical ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.isCritical ? Color(.sRGB, red: 0xE0/255, green: 0x7A/255, blue: 0x72/255, opacity: 1) : Color(.sRGB, red: 0xE6/255, green: 0xB0/255, blue: 0x5C/255, opacity: 1))
                    .font(.callout)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.isCritical {
                    Button(action: { bus.dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.6))
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(capsuleBackground)
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                guard !notice.isCritical else { return }
                let item = DispatchWorkItem { bus.dismiss() }
                dismissWorkItem?.cancel()
                dismissWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
            }
            .onDisappear { dismissWorkItem?.cancel() }
        }
    }

    @ViewBuilder
    private var capsuleBackground: some View {
        // Deep neutral glass pill: a dark translucent fill that reads as the
        // design's bottom toast on both platforms.
        let dark = Color(.sRGB, red: 0x22/255, green: 0x24/255, blue: 0x2E/255, opacity: 0.92)
        #if os(macOS)
        Capsule()
            .fill(dark)
            .glassEffect(.regular, in: Capsule())
        #else
        Capsule()
            .fill(dark)
        #endif
    }
}
