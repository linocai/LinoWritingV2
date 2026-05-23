import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct BookCardView: View {
    public let book: Book

    @State private var isHovered: Bool = false

    public init(book: Book) { self.book = book }

    private var coverColor: Color {
        if let hex = book.coverColor { return Color(hex: hex) }
        return Color.accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(coverColor)
                .overlay(
                    Text(book.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                )
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .shadow(
                    color: .black.opacity(isHovered ? 0.25 : 0.15),
                    radius: isHovered ? 8 : 4,
                    y: isHovered ? 3 : 1
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 4)
        .offset(y: isHovered ? -2 : 0)
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }

    private var footnote: String {
        let chapters = "\(book.chapterCount) 章"
        if let opened = book.lastOpenedAt {
            return "\(chapters) · 上次打开 \(opened.relativeShort)"
        }
        return chapters
    }
}

private extension Date {
    var relativeShort: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
