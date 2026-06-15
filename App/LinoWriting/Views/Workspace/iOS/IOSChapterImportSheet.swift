#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P4) — iOS variant of the legacy `ImportChapterSheet`.
///
/// Handoff `LinoWriting iOS.dc.html` 屏3 ··· 菜单·导入文本. The author pastes an
/// already-written chapter body; on success the chapter transitions straight to
/// `finalized` with `source == .imported` (`POST /chapters/{id}/import`).
///
/// Mirrors `ImportChapterSheet`'s contract exactly — import only lands the body
/// (`run_extractor=false`, per v0.9.3 §5.DI); extraction is the separate manual
/// "提取角色/时间线" action on the editor footer. iOS-only glass grouped sheet
/// (栅格 `#F2F2F7`), pinned header/footer so the 取消/导入 row never clips.
struct IOSChapterImportSheet: View {
    let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
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
                        Text("导入只保存正文；之后可在正文区点「提取角色/时间线」更新角色卡 / 时间线。")
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
        // §5.DI: import only lands the body (run_extractor=false); extraction is
        // a separate manual step so this doesn't fan out into character highlights.
        let payload = ChapterImportRequest(
            draftText: trimmedDraft,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            summary: nil,
            runExtractor: false
        )
        isSubmitting = true
        Task {
            let result = await chapterEditorStore.importChapter(payload)
            isSubmitting = false
            guard let result else { return } // error already on ErrorBus; keep sheet open
            chaptersStore.upsert(result.chapter)
            dismiss()
        }
    }
}
#endif
