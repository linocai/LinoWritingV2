#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 章节 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 章节 tab:
///   - chapter row card: 第 N 章 + status badge (radius-6 tinted) + Songti
///     chapter name + ›, pushing the chapter editor.
///   - bottom dashed "＋ 新建章节" (`POST /books/{id}/chapters`).
///
/// Reads `ChaptersStore.sorted` (`GET /books/{id}/chapters`, loaded on book
/// open). Rows push via a destination-based `NavigationLink` so the existing
/// book-level `[Book]` path bridge (`RootViewIOS.bookPath`, pinned by
/// `NavigationShellIOSTests`) is untouched — chapter pushes are managed by the
/// stack internally. P3 destination = `IOSChapterEditPlaceholder` (the legacy
/// editor behind the seam); P4 swaps in the new three-step editor. iOS-only.
struct IOSChaptersSection: View {
    let book: Book

    @EnvironmentObject var chaptersStore: ChaptersStore

    @State private var isCreating = false
    /// v1.3.1 (KK) P2 — long-press "删除" entry (the row is a plain `VStack`
    /// + `NavigationLink`, not a `List`, so `.swipeActions` doesn't apply —
    /// `.contextMenu` is the correct iOS affordance here).
    @State private var pendingDelete: ChapterSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chaptersStore.isLoading && chaptersStore.chapters.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if chaptersStore.chapters.isEmpty {
                emptyState
            } else {
                ForEach(chaptersStore.sorted) { chapter in
                    NavigationLink {
                        IOSChapterEditPlaceholder(chapterId: chapter.id, bookTitle: book.title)
                    } label: {
                        row(chapter)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = chapter } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            newChapterButton
        }
        .alert("删除这一章？",
               isPresented: .constant(pendingDelete != nil),
               presenting: pendingDelete) { chapter in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = chapter
                pendingDelete = nil
                Task { await chaptersStore.delete(id: target.id) }
            }
        } message: { _ in
            Text("章节及其正文、结构化提示、关联事件都会删除，且无法撤销。")
        }
    }

    // MARK: - Row card

    private func row(_ chapter: ChapterSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(LWColor.mutedText3)
                    IOSStatusChip(status: chapter.status)
                }
                Text(chapter.title?.nonEmptyOr("未命名") ?? "未命名")
                    .font(LWFont.songti(16, weight: .semibold))
                    .foregroundStyle(LWColor.bodyText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
        .shadow(
            color: Color(.sRGB, red: 20/255, green: 28/255, blue: 60/255, opacity: 0.4),
            radius: 12, y: 6
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var newChapterButton: some View {
        Button { createChapter() } label: {
            HStack(spacing: 6) {
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("＋ 新建章节")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(LWColor.accentText)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(LWColor.accentStart.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(LWColor.accentStart.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("还没有章节")
                .font(.system(size: 14)).foregroundStyle(LWColor.mutedText3)
            Text("点下面「＋ 新建章节」开始第一章")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func createChapter() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            _ = await chaptersStore.create(userPrompt: "", title: nil)
            isCreating = false
        }
    }
}

// MARK: - Status chip (radius-6 tinted, matches the handoff chapter row)

/// The handoff chapter row uses a 6-radius rounded-rect status pill (not the
/// capsule `StatusBadge`). Colours come from the same `ChapterStatus` source as
/// `StatusBadge` (and the handoff `statusMeta`) so the two stay in lock-step.
struct IOSStatusChip: View {
    let status: ChapterStatus
    /// v1.4.0 (MM) P4 — optional label swap while keeping `status`'s color
    /// (mirrors macOS `StatusBadge.overrideLabel`; "修订中" over the
    /// `.writing` blue during the two-pass compression sub-phase, which
    /// server-side is still `status=="writing"`).
    var overrideLabel: String? = nil

    var body: some View {
        Text(overrideLabel ?? status.label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var palette: (text: Color, background: Color) {
        switch status {
        case .draft:       return (LWColor.hex(0x9499AD), Self.rgba(148, 153, 173, 0.14))
        case .promptReady: return (LWColor.hex(0xB8731F), Self.rgba(214, 150, 40, 0.16))
        case .writing:     return (LWColor.hex(0x4A63F0), Self.rgba(74, 99, 240, 0.16))
        case .draftReady:  return (LWColor.hex(0x1F7A8C), Self.rgba(31, 140, 150, 0.16))
        case .finalized:   return (LWColor.hex(0x2F8F5B), Self.rgba(47, 143, 91, 0.16))
        }
    }

    private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
}

extension String {
    /// Returns `self` if non-empty, else `fallback`.
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
