#if os(macOS)
import SwiftUI
import AppKit

/// v1.1.0 (FF) Phase 2 — macOS Liquid Glass book card.
///
/// Pixel-exact transcription of the handoff bookshelf card
/// (`LinoWriting.dc.html` 书架 / `README.md` §1.书架):
///   - card: radius 16, glass `rgba(255,255,255,0.62)`, 0.5px hairline,
///     top-highlight inset + soft drop shadow; hover lifts 3px.
///   - cover: 132 high, `cover_color` six-colour gradient, a top→bottom
///     `rgba(255,255,255,0.18) → rgba(0,0,0,0.14)` darkening wash, book name
///     in 23px Songti white with a soft text shadow, pinned to the bottom.
///   - body: "N 章 · N 角色" (12.5px #6b7085, middot at 0.4 opacity) + last
///     opened label (12px #9499ad).
///
/// macOS-only — the iOS bookshelf keeps the existing `BookCardView`.
struct BookCardGlassView: View {
    let book: Book
    /// Fires on click → caller runs `appStore.openBook` + `POST /books/{id}/touch`.
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            footer
        }
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.25)
                .stroke(LWMetrics.hairline, lineWidth: LWMetrics.hairlineWidth)
        )
        .overlay(
            // inset 0 1px 0 rgba(255,255,255,0.7) — top edge highlight.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        // 0 14px 30px -20px rgba(20,28,60,0.4); hover → 0 22px 44px -22px @0.55.
        .shadow(
            color: Color(.sRGB, red: 20/255, green: 28/255, blue: 60/255, opacity: isHovered ? 0.55 : 0.4),
            radius: isHovered ? 22 : 15,
            y: isHovered ? 12 : 8
        )
        .offset(y: isHovered ? -3 : 0)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Cover (132 high, gradient + darkening wash + serif title)

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            LWColor.coverGradient(book.coverColor)
            // linear-gradient(180deg, rgba(255,255,255,0.18), rgba(0,0,0,0.14))
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.black.opacity(0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
            Text(book.title)
                .font(LWFont.songti(23, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .lineSpacing(23 * 0.2)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                .padding(16)
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer ("N 章 · N 角色" + last opened)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(book.chapterCount) 章")
                Text("·").opacity(0.4)
                Text("\(book.characterCount) 角色")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(LWColor.hex(0x6B7085))

            Text(lastOpenedLabel)
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText3) // #9499AD
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
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
