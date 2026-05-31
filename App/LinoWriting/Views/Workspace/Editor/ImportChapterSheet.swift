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

                    // PROJECT_PLAN v0.9.3 §5.DI: import only saves the body
                    // (never touches the LLM). Extraction is now a separate
                    // manual step on the toolbar.
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("导入只保存正文；之后可在工具栏点「提取角色/时间线」更新角色卡 / 时间线。")
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
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 560, maxHeight: 560)
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

        // PROJECT_PLAN v0.9.3 §5.DI: import only lands the body
        // (run_extractor=false). Extraction is a separate manual step on the
        // toolbar, so this no longer fans out into character highlights.
        let payload = ChapterImportRequest(
            // Send the trimmed version so the backend stores clean text; we
            // still keep the user's in-sheet `draftText` untouched in case
            // they cancel and re-edit.
            draftText: trimmedDraft,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
            runExtractor: false
        )

        isSubmitting = true
        Task {
            let result = await chapterEditorStore.importChapter(payload)
            isSubmitting = false
            guard let result else {
                // Error already published to ErrorBus by the store. Keep the
                // sheet open so the user can fix and retry without re-pasting.
                return
            }
            // Sync the sidebar list so the status pill flips to finalized /
            // source=imported. No character refresh — import doesn't extract.
            chaptersStore.upsert(result.chapter)
            dismiss()
        }
    }
}
