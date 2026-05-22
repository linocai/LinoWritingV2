import SwiftUI

public struct ErrorBanner: View {
    @EnvironmentObject private var bus: ErrorBus
    @State private var dismissWorkItem: DispatchWorkItem?

    public init() {}

    public var body: some View {
        if let notice = bus.current {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.isCritical ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Spacer()
                Button(action: { bus.dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(notice.isCritical ? Color.red : Color(red: 0.85, green: 0.35, blue: 0.30))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
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
