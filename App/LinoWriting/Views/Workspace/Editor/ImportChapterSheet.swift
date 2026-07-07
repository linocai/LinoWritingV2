import SwiftUI

/// Modal sheet for the §5.A "import existing chapter text" flow.
///
/// The user pastes their already-written chapter body, optionally overwrites
/// title / summary, and chooses whether the backend should run the Extractor
/// (character updates + timeline) after import. On success the chapter
/// transitions straight to `finalized` with `source == .imported`.
///
/// Why it lives next to `ChapterEditorView` (and not under `Sidebar/`):
/// the entry button sits inside `ChapterToolbar`, parallel to "展开提纲" /
/// "完成". Keeping the sheet adjacent to its owner matches the editor
/// folder convention.
public struct ImportChapterSheet: View {
    public let chapter: Chapter

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    // v1.3.1 (KK) P4: single-chapter import now auto-extracts — need the
    // characters store to mirror `finalize()`'s right-panel highlight.
    @EnvironmentObject var charactersStore: CharactersStore
    // v1.3.1 (KK) 审后修复 🟡#2: need `environment` (for `apiClient.getChapter`
    // + `errorBus`) to re-check chapter state after a two-phase import
    // failure — see `submit()`'s failure branch.
    @EnvironmentObject var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var draftText: String = ""
    @State private var titleOverride: String = ""
    @State private var summaryOverride: String = ""
    @State private var isSubmitting: Bool = false

    // PROJECT_PLAN §5.K.4 (字体): the import body uses the user's serif/sans
    // preference so the paste preview matches the editor's reading
    // experience (Step3_DraftView reads the same key).
    @AppStorage(Settings.editorFontDesignKey) private var fontDesignRaw: String = EditorFontDesign.default.rawValue

    private var bodyFontDesign: Font.Design {
        (EditorFontDesign(rawValue: fontDesignRaw) ?? .default).fontDesign
    }

    public init(chapter: Chapter) {
        self.chapter = chapter
    }

    public var body: some View {
        // PROJECT_PLAN v0.9.3 §5.DI.3: same footer-pinning fix as
        // NewChapterSheet — header + footer stay outside the ScrollView so
        // the "取消 / 导入" row is always visible, even in the K-1 minimum
        // window (880×580) where the greedy TextEditor would otherwise push
        // the footer off the bottom edge.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("章节正文")
                            .font(.callout.weight(.medium))
                        Text("把已写好的整章正文粘贴在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draftText)
                            .font(.system(.body, design: bodyFontDesign))
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, maxHeight: .infinity)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.25))
                            )
                        Text("\(trimmedDraftCount) 字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题（可选）")
                            .font(.callout.weight(.medium))
                        TextField(titlePlaceholder, text: $titleOverride)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("章节摘要（可选）")
                            .font(.callout.weight(.medium))
                        TextField("留空保存为空摘要", text: $summaryOverride, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }

                    // v1.3.1 (KK) P4: single-chapter import now auto-runs the
                    // Extractor (推翻 v0.9.3 §5.DI「import 只落正文,提取纯手动」).
                    // The manual "提取角色/时间线" toolbar button still exists
                    // for re-runs / the finalized-态 case.
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("导入后将自动提取角色 / 时间线；若解析失败，正文仍会保留，可在工具栏重新提取。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Spacer()
                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("导入")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        // A-2 reviewer 🟡 #8: keep minHeight modest so the sheet still fits
        // inside the K-1 minimum window (880×580). idealHeight stays larger
        // so on roomy displays the sheet still feels generous; maxHeight caps
        // it to the K-1 window so the footer can't clip below the bottom edge.
        //
        // v0.9.x iOS fix: macOS-only. minWidth 560 (> iPhone ~393pt) forced the
        // sheet content to overflow off both edges on iOS. The system presents
        // iOS sheets full-width; no explicit size needed there.
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 560, maxHeight: 560)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("导入文本")
                    .font(.title3.weight(.semibold))
                Text("第 \(chapter.index) 章 · 当前状态：\(chapter.status.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var titlePlaceholder: String {
        if let t = chapter.title, !t.isEmpty {
            return "沿用现有：\(t)"
        }
        return "章节标题（可留空）"
    }

    /// Trimmed character count keeps the displayed total honest — leading /
    /// trailing whitespace from pasted clipboard text doesn't inflate it.
    private var trimmedDraftCount: Int {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSubmit: Bool {
        !isSubmitting && trimmedDraftCount > 0
    }

    private func submit() {
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }
        let trimmedTitle = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        // v1.3.1 (KK) P4: single-chapter import now runs the Extractor
        // (推翻 v0.9.3 §5.DI「import 只落正文,提取纯手动」). The backend's
        // import endpoint is two-phase for this path — body/title/source/
        // finalized commits first, extraction is a second transaction whose
        // failure only rolls back its own output (chapter this sheet edits
        // already exists, unlike NewChapterSheet's create+import two-step,
        // so there's no "stranded skeleton" risk here on extractor failure —
        // worst case the chapter is finalized with正文 intact and no error
        // dialog beyond the ErrorBus toast; the toolbar's manual "提取角色/
        // 时间线" lets the author retry).
        let payload = ChapterImportRequest(
            // Send the trimmed version so the backend stores clean text; we
            // still keep the user's in-sheet `draftText` untouched in case
            // they cancel and re-edit.
            draftText: trimmedDraft,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
            runExtractor: true
        )

        isSubmitting = true
        Task {
            let result = await chapterEditorStore.importChapter(payload)
            isSubmitting = false
            guard let result else {
                // v1.3.1 (KK) 审后修复 🟡#2: with the two-phase backend
                // commit, a thrown error here can mean the body/finalize
                // already landed and only the Extractor step failed — the
                // old "just keep the sheet open" behavior left the editor
                // showing a stale non-finalized chapter, so retrying "导入"
                // in this same sheet hit the backend's status whitelist
                // (finalized chapters reject import) as a confusing 409,
                // and the "工具栏重新提取" entry the ErrorBus toast points to
                // never appeared (it only shows once `finalized`). Re-GET to
                // find out which case this is before deciding whether to
                // keep the sheet open.
                await handleImportFailure()
                return
            }
            // Sync the sidebar list so the status pill flips to finalized /
            // source=imported, and mirror finalize()'s right-panel highlight
            // for any characters the Extractor touched.
            chaptersStore.upsert(result.chapter)
            charactersStore.markUpdated(result.updatedCharacterIds)
            if !result.updatedCharacterIds.isEmpty {
                await charactersStore.load(bookId: result.chapter.bookId)
            }
            dismiss()
        }
    }

    /// v1.3.1 (KK) 审后修复 🟡#2 — mirrors `NewChapterSheet`'s post-failure
    /// re-check (which only has to handle "landed" vs "not landed" here,
    /// since this sheet edits an existing chapter — there's no skeleton to
    /// delete either way, so an inconclusive GET can safely fall through to
    /// "keep the sheet open", unlike `NewChapterSheet`'s three-state case).
    private func handleImportFailure() async {
        guard let reloaded = try? await environment.apiClient.getChapter(id: chapter.id) else {
            // GET itself failed — inconclusive; the original ErrorBus toast
            // from the import call already told the user something went
            // wrong. Keep the sheet open so they can retry.
            return
        }
        guard reloaded.status == .finalized, !(reloaded.draftText ?? "").isEmpty else {
            // Confirmed not landed — safe to keep the sheet open for retry.
            return
        }
        // Body committed; only the extractor step failed upstream. Close
        // the sheet and refresh so the editor shows the real (finalized)
        // state and the "重新提取" button becomes visible; surface a
        // second, clearer Toast on top of the generic upstream one.
        chaptersStore.upsert(reloaded)
        await chapterEditorStore.load(chapterId: chapter.id)
        environment.errorBus.publish("正文已导入，提取失败可在工具栏手动重试", critical: false)
        dismiss()
    }
}
