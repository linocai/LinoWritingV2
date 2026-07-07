#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P4) — iOS variant of the legacy `ImportChapterSheet`.
///
/// Handoff `LinoWriting iOS.dc.html` 屏3 ··· 菜单·导入文本. The author pastes an
/// already-written chapter body; on success the chapter transitions straight to
/// `finalized` with `source == .imported` (`POST /chapters/{id}/import`).
///
/// Mirrors `ImportChapterSheet`'s contract — single-chapter import now runs
/// the Extractor (v1.3.1 KK P4: 推翻 v0.9.3 §5.DI「import 只落正文,提取纯
/// 手动」，作者拍板单章导入即提取). Backend import endpoint is two-phase for
/// this path: body/title/source/finalized commits first, extraction runs as
/// a second transaction whose failure only rolls back its own output — the
/// chapter stays `finalized` with正文 intact even if extraction errors
/// upstream; the manual "提取角色/时间线" action on the editor footer still
/// exists for retries. iOS-only glass grouped sheet (栅格 `#F2F2F7`), pinned
/// header/footer so the 取消/导入 row never clips.
struct IOSChapterImportSheet: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    // v1.3.1 (KK) 审后修复 🟡#2: need `environment` (apiClient.getChapter +
    // errorBus) to re-check chapter state after a two-phase import failure —
    // mirrors `ImportChapterSheet`'s identical fix.
    @EnvironmentObject var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var draftText = ""
    @State private var titleOverride = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("章节正文")
                        Text("把已写好的整章正文粘贴在这里。")
                            .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                        LWTextArea(
                            text: $draftText,
                            placeholder: "粘贴本章正文…",
                            minHeight: 220,
                            font: LWFont.songti(15),
                            lineSpacing: 6,
                            background: Color.white.opacity(0.85)
                        )
                        Text("\(trimmedCount) 字")
                            .font(.system(size: 11.5)).foregroundStyle(LWColor.mutedText3)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("标题 · 可选")
                        TextField(titlePlaceholder, text: $titleOverride)
                            .font(LWFont.songti(16))
                            .foregroundStyle(LWColor.bodyText)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(LWColor.mutedText3)
                        Text("导入后将自动提取角色 / 时间线；若解析失败，正文仍会保留，可在正文区重新提取。")
                            .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("导入文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(LWColor.accentText)
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting { ProgressView() } else { Text("导入").fontWeight(.semibold) }
                    }
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText)
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(LWColor.secondaryText)
    }

    private var titlePlaceholder: String {
        if let t = chapter.title, !t.isEmpty { return "沿用现有：\(t)" }
        return "章节标题（可留空）"
    }

    private var trimmedCount: Int {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).count
    }
    private var canSubmit: Bool { !isSubmitting && trimmedCount > 0 }

    private func submit() {
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }
        let trimmedTitle = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        // v1.3.1 (KK) P4: single-chapter import now runs the Extractor
        // (推翻 v0.9.3 §5.DI). Backend two-phase commit means a thrown error
        // here can mean "body committed, extractor failed upstream" rather
        // than nothing landing — this sheet edits an existing chapter (not a
        // freshly-created skeleton like NewChapterSheet), so there's no
        // stranded-skeleton risk; worst case is a finalized chapter with正文
        // intact and an ErrorBus toast, retryable via the manual extract button.
        let payload = ChapterImportRequest(
            draftText: trimmedDraft,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            summary: nil,
            runExtractor: true
        )
        isSubmitting = true
        Task {
            let result = await chapterEditorStore.importChapter(payload)
            isSubmitting = false
            guard let result else {
                // v1.3.1 (KK) 审后修复 🟡#2 — same re-check as
                // `ImportChapterSheet` (macOS twin): a thrown error post
                // two-phase-commit can mean "body landed, extractor failed"
                // rather than nothing landing at all.
                await handleImportFailure()
                return
            }
            chaptersStore.upsert(result.chapter)
            charactersStore.markUpdated(result.updatedCharacterIds)
            if !result.updatedCharacterIds.isEmpty {
                await charactersStore.load(bookId: result.chapter.bookId)
            }
            dismiss()
        }
    }

    /// v1.3.1 (KK) 审后修复 🟡#2 — mirrors `ImportChapterSheet.handleImportFailure`.
    private func handleImportFailure() async {
        guard let reloaded = try? await environment.apiClient.getChapter(id: chapter.id) else {
            // GET itself failed — inconclusive; keep the sheet open.
            return
        }
        guard reloaded.status == .finalized, !(reloaded.draftText ?? "").isEmpty else {
            // Confirmed not landed — keep the sheet open for retry.
            return
        }
        chaptersStore.upsert(reloaded)
        await chapterEditorStore.load(chapterId: chapter.id)
        environment.errorBus.publish("正文已导入，提取失败可在正文区手动重试", critical: false)
        dismiss()
    }
}
#endif
