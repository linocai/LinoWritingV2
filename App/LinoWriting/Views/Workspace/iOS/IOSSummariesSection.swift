#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 梗概 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 梗概 tab:
///   - "已完成章节的梗概 · 作为后续章节的上下文" hint.
///   - one card per finalized chapter: Songti "第 N 章 · {标题}" + summary text.
///
/// Reads finalized chapters from `ChaptersStore`; the summary body is fetched
/// lazily per card via `ChaptersStore.ensureSummary` (`GET /chapters/{id}`,
/// idempotent — zero new endpoint). Mirrors `MacSummariesTab`. iOS-only.
struct IOSSummariesSection: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    private var finalized: [ChapterSummary] {
        chaptersStore.chapters.filter { $0.status == .finalized }.sorted { $0.index > $1.index }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("已完成章节的梗概 · 作为后续章节的上下文")
                .font(.system(size: 13))
                .foregroundStyle(LWColor.mutedText3)
                .padding(.bottom, 3)

            if finalized.isEmpty {
                Text("还没有已完成的章节")
                    .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
            } else {
                ForEach(finalized) { summary in
                    card(summary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ summary: ChapterSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label(summary))
                .font(LWFont.songti(14, weight: .bold))
                .foregroundStyle(LWColor.bodyText)
            Text(text(summary))
                .font(.system(size: 13))
                .foregroundStyle(LWColor.secondaryText2)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
        .task { await chaptersStore.ensureSummary(chapterId: summary.id) }
    }

    private func label(_ s: ChapterSummary) -> String {
        if let t = s.title, !t.isEmpty { return "第 \(s.index) 章 · \(t)" }
        return "第 \(s.index) 章"
    }

    private func text(_ s: ChapterSummary) -> String {
        if let cached = chaptersStore.summaryTexts[s.id] { return cached }
        if let live = chapterEditorStore.chapter, live.id == s.id, let summary = live.summary { return summary }
        return "加载中…"
    }
}
#endif
