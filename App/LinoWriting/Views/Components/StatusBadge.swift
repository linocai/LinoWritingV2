import SwiftUI

public struct StatusBadge: View {
    public let status: ChapterStatus

    public init(_ status: ChapterStatus) { self.status = status }

    public var body: some View {
        // PROJECT_PLAN §5.K.4 (字体段): `.contentTransition(.numericText())` lets
        // the label morph between states (e.g. 写作中 → 正文完成) rather than
        // hard-snap. The outer `.animation(.smooth, value: status)` is what
        // actually drives the transition — without it, contentTransition is inert.
        Text(status.label)
            .font(.caption2.weight(.medium))
            .contentTransition(.numericText())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .animation(.smooth(duration: 0.3), value: status)
    }

    private var tint: Color {
        switch status {
        case .draft: return .secondary
        case .promptReady: return .blue
        case .writing: return .orange
        case .draftReady: return .indigo
        case .finalized: return .green
        }
    }
}

#Preview {
    HStack {
        ForEach(ChapterStatus.allCases, id: \.self) { StatusBadge($0) }
    }
    .padding()
}
