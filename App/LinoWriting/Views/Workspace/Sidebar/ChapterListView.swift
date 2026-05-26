import SwiftUI

public struct ChapterListView: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore

    @State private var pendingDeleteId: String?
    @State private var hoveredChapterId: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .background(.regularMaterial)
        .sheet(isPresented: $chaptersStore.showNewChapterSheet) {
            NewChapterSheet()
        }
    }

    private var header: some View {
        HStack {
            Text("章节")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List(selection: $chaptersStore.selectedChapterId) {
            ForEach(chaptersStore.sorted) { chapter in
                rowWithAffordances(chapter: chapter)
                    .tag(Optional(chapter.id))
            }
        }
        .listStyle(.sidebar)
        .alert("删除这一章？",
               isPresented: .constant(pendingDeleteId != nil),
               presenting: pendingDeleteId) { id in
            Button("取消", role: .cancel) { pendingDeleteId = nil }
            Button("删除", role: .destructive) {
                let target = id
                pendingDeleteId = nil
                Task { await chaptersStore.delete(id: target) }
            }
        } message: { _ in
            Text("章节及其正文、结构化提示、关联事件都会删除。")
        }
    }

    /// v0.8 §5.R.5 — platform affordance wrapper around `row(...)`.
    /// macOS keeps the right-click context menu; iOS picks up a trailing
    /// swipe-to-delete (destructive, full-swipe disabled so the user
    /// can't blow a chapter away by accident).
    @ViewBuilder
    private func rowWithAffordances(chapter: ChapterSummary) -> some View {
        #if os(macOS)
        row(chapter: chapter)
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeleteId = chapter.id
                } label: { Text("删除") }
            }
        #else
        row(chapter: chapter)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeleteId = chapter.id
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        #endif
    }

    private func row(chapter: ChapterSummary) -> some View {
        let isHovered = hoveredChapterId == chapter.id
        return HStack(spacing: 6) {
            Text("第 \(chapter.index) 章")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            // PROJECT_PLAN §5.A.6 nice-to-have: a subtle marker for
            // imported chapters so users can tell at a glance which rows
            // came from their own pasted text vs. the Agent's draft.
            if chapter.source == .imported {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("用户导入的章节")
                    .accessibilityLabel("用户导入")
            }
            if let title = chapter.title, !title.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusBadge(chapter.status)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        #if os(macOS)
        .onHover { hovering in
            hoveredChapterId = hovering ? chapter.id : (hoveredChapterId == chapter.id ? nil : hoveredChapterId)
        }
        #endif
    }

    private var footer: some View {
        Button {
            chaptersStore.showNewChapterSheet = true
        } label: {
            Label("新建章节", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
