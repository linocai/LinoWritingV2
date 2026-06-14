#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 梗概 tab. Finalized chapters' summary cards (later
/// chapters' context). macOS-only.
struct MacSummariesTab: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    private var finalized: [ChapterSummary] {
        chaptersStore.chapters.filter { $0.status == .finalized }.sorted { $0.index > $1.index }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已完成章节的梗概 · 作为后续章节的上下文")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                .padding(.vertical, 6).padding(.horizontal, 2)

            if finalized.isEmpty {
                Text("还没有已完成的章节")
                    .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ForEach(finalized) { summary in
                    card(summary)
                }
            }
        }
    }

    private func card(_ summary: ChapterSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label(summary))
                .font(LWFont.songti(12.5, weight: .bold))
                .foregroundStyle(LWColor.bodyText)
            Text(text(summary))
                .font(.system(size: 12.5))
                .foregroundStyle(LWColor.secondaryText2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
