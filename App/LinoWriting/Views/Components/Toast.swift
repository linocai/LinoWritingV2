import SwiftUI

/// Bottom-trailing toast notification driven by `ErrorBus`.
///
/// Per PROJECT_PLAN §5.K.4 (Toast section): replaces the v0.5 top-banner with a
/// `.thinMaterial` rounded-rectangle floating in the bottom-right corner.
/// Behaviour preserved from `ErrorBanner`:
/// - Non-critical notices auto-dismiss after 3 seconds.
/// - Critical (401) notices stick around until the user dismisses them.
public struct Toast: View {
    @EnvironmentObject private var bus: ErrorBus
    @State private var dismissWorkItem: DispatchWorkItem?

    public init() {}

    public var body: some View {
        // `.animation(.smooth, value:)` at the container level drives the
        // .transition below — without it the move/opacity is a hard snap.
        // K-2 reviewer-flagged. K-3 will layer broader animation policy.
        Group {
            content
        }
        .animation(.smooth(duration: 0.25), value: bus.current?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let notice = bus.current {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.isCritical ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.isCritical ? Color.red : Color.orange)
                    .font(.body)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: { bus.dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        notice.isCritical ? Color.red.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .onAppear {
                guard !notice.isCritical else { return }
                let item = DispatchWorkItem { bus.dismiss() }
                dismissWorkItem?.cancel()
                dismissWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
            }
            .onDisappear { dismissWorkItem?.cancel() }
        }
    }
}
