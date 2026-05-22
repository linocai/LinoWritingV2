import SwiftUI

public struct SummariesTabView: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    public init() {}

    private var finalized: [ChapterSummary] {
        chaptersStore.chapters
            .filter { $0.status == .finalized }
            .sorted { $0.index > $1.index }
    }

    public var body: some View {
        Group {
            if finalized.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(finalized) { summary in
                            row(summary)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("已完成的章节会在这里展示摘要")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ summary: ChapterSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("第 \(summary.index) 章")
                    .font(.callout.weight(.semibold))
                if let title = summary.title, !title.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看正文") { chaptersStore.selectedChapterId = summary.id }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Text(summaryText(for: summary))
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .task {
            // Prefer the in-memory editor chapter if it matches; else fetch.
            if let live = chapterEditorStore.chapter, live.id == summary.id, let s = live.summary {
                if chaptersStore.summaryTexts[summary.id] != s {
                    // No publisher write here; ChaptersStore handles caching.
                }
            }
            await chaptersStore.ensureSummary(chapterId: summary.id)
        }
    }

    private func summaryText(for summary: ChapterSummary) -> String {
        if let s = chaptersStore.summaryTexts[summary.id] { return s }
        if let live = chapterEditorStore.chapter, live.id == summary.id, let s = live.summary { return s }
        return "加载中…"
    }
}
