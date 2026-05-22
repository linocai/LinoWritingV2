import SwiftUI

public struct StatusBadge: View {
    public let status: ChapterStatus

    public init(_ status: ChapterStatus) { self.status = status }

    public var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
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
