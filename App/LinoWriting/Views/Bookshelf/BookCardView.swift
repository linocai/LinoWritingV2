import SwiftUI

public struct BookCardView: View {
    public let book: Book

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
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)

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
