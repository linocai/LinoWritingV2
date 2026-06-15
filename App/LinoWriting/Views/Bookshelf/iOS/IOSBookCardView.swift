#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P2) — iPhone Liquid Glass book card (two-column shelf grid).
///
/// Pixel-exact transcription of the handoff bookshelf card
/// (`LinoWriting iOS.dc.html` 书架 / README §1.书架):
///   - card: radius 18, glass `rgba(255,255,255,0.66)`, 0.5px hairline,
///     top-edge highlight inset + soft drop shadow.
///   - cover: **150 high**, `cover_color` six-colour gradient, a top→bottom
///     `rgba(255,255,255,0.16) → rgba(0,0,0,0.16)` darkening wash, book name
///     in 22px Songti white pinned bottom-left with a soft text shadow.
///   - footer (`11/13/13` padding): "N 章 · N 角色" (12px #6B7085, middot at
///     0.4 opacity) + last-opened label (11.5px #9499AD).
///
/// iOS-only. macOS keeps `BookCardGlassView` (132-high cover, 23px title).
struct IOSBookCardView: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            footer
        }
        .background(Color.white.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .inset(by: 0.25)
                .stroke(LWMetrics.hairlineLight, lineWidth: LWMetrics.hairlineWidth)
        )
        .overlay(
            // inset 0 1px 0 rgba(255,255,255,0.7) — top edge highlight.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .inset(by: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [LWMetrics.topHighlight, .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        // 0 14px 30px -20px rgba(20,28,60,0.4).
        .shadow(
            color: Color(.sRGB, red: 20/255, green: 28/255, blue: 60/255, opacity: 0.4),
            radius: 15,
            y: 8
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Cover (150 high, gradient + darkening wash + serif title)

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            LWColor.coverGradient(book.coverColor)
            // linear-gradient(180deg, rgba(255,255,255,0.16), rgba(0,0,0,0.16))
            LinearGradient(
                colors: [Color.white.opacity(0.16), Color.black.opacity(0.16)],
                startPoint: .top,
                endPoint: .bottom
            )
            Text(book.title)
                .font(LWFont.songti(22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .lineSpacing(22 * 0.2)
                .shadow(color: .black.opacity(0.32), radius: 4, y: 1)
                .padding(14)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer ("N 章 · N 角色" + last opened)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(book.chapterCount) 章")
                Text("·").opacity(0.4)
                Text("\(book.characterCount) 角色")
            }
            .font(.system(size: 12))
            .foregroundStyle(LWColor.hex(0x6B7085))

            Text(lastOpenedLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(LWColor.mutedText3) // #9499AD
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 13)
    }

    /// "今天 14:22" / "昨天 21:08" / "3 天前" — matches the handoff's
    /// `lastOpenedLabel` phrasing. Falls back to "尚未打开" when never opened.
    private var lastOpenedLabel: String {
        guard let opened = book.lastOpenedAt else { return "尚未打开" }
        let cal = Calendar.current
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "zh_CN")
        timeFmt.dateFormat = "HH:mm"
        if cal.isDateInToday(opened) {
            return "今天 \(timeFmt.string(from: opened))"
        }
        if cal.isDateInYesterday(opened) {
            return "昨天 \(timeFmt.string(from: opened))"
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: opened), to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 {
            return "\(days) 天前"
        }
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "M 月 d 日"
        return dateFmt.string(from: opened)
    }
}
#endif
