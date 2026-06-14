#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — macOS workspace left column (chapter sidebar).
///
/// Handoff `LinoWriting.dc.html` 工作台 LEFT:
///   - header: "章节" kicker (11px / 700 / 0.22em) + "N 章 · N 角色" meta +
///     "＋新建章节" 28×28 button (`POST /chapters` via the existing
///     `showNewChapterSheet`).
///   - list: each row = "第 N 章" + StatusBadge + chapter name (Songti);
///     selected row = `rgba(74,99,240,0.08)` fill + accent hairline border.
///   - footer: "导出整本…" → `GET /books/{id}/export` (format + include_drafts).
///
/// `.lwSidebar()` glass. macOS-only.
struct MacChapterSidebar: View {
    let book: Book
    /// Unused now (export handled inline); kept so the container can inject hooks.
    var onExport: () -> Void = {}

    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var environment: AppEnvironment

    @State private var pendingDeleteId: String?
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            chapterList
            footer
        }
        .frame(maxHeight: .infinity)
        .lwSidebar()
        .overlay(alignment: .trailing) {
            Rectangle().fill(LWMetrics.hairlineLight).frame(width: 0.5)
        }
        .sheet(isPresented: $chaptersStore.showNewChapterSheet) {
            NewChapterSheet()
        }
        .sheet(isPresented: $showExportSheet) {
            MacExportSheet(book: book)
        }
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("章节")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.22 * 11)
                    .foregroundStyle(LWColor.mutedText3)
                    .textCase(.uppercase)
                Text("\(book.chapterCount) 章 · \(book.characterCount) 角色")
                    .font(.system(size: 12))
                    .foregroundStyle(LWColor.mutedText3)
            }
            Spacer()
            Button { chaptersStore.showNewChapterSheet = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LWColor.accentText)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .onHover { pointer($0) }
            .help("新建章节")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var chapterList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(chaptersStore.sorted) { chapter in
                    chapterRow(chapter)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private func chapterRow(_ chapter: ChapterSummary) -> some View {
        let selected = chaptersStore.selectedChapterId == chapter.id
        return Button {
            chaptersStore.selectedChapterId = chapter.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LWColor.mutedText3)
                    Spacer(minLength: 6)
                    StatusBadge(chapter.status)
                }
                Text(chapterTitle(chapter))
                    .font(LWFont.songti(14.5, weight: .semibold))
                    .foregroundStyle(selected ? LWColor.accentDeep : LWColor.bodyText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? LWColor.accentStart.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? LWColor.accentStart.opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
        .contextMenu {
            Button(role: .destructive) { pendingDeleteId = chapter.id } label: { Text("删除") }
        }
    }

    private func chapterTitle(_ chapter: ChapterSummary) -> String {
        if let t = chapter.title, !t.isEmpty { return t }
        return "未命名章节"
    }

    // MARK: - Footer (导出整本…)

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(LWMetrics.hairlineLight).frame(height: 0.5)
            LWBorderedButton(title: "导出整本…", height: 34, fullWidth: true) {
                showExportSheet = true
            }
            .padding(10)
        }
    }
}
#endif
