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
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftText: String = ""
    @State private var titleOverride: String = ""
    @State private var summaryOverride: String = ""
    @State private var runExtractor: Bool = true
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
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

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
                    .frame(minHeight: 280, maxHeight: .infinity)
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
                TextField("留空可让 Agent 自动总结", text: $summaryOverride, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Toggle(isOn: $runExtractor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入后让 Agent 提取角色更新和时间线")
                        .font(.callout)
                    Text("关闭后只保存原文与章节摘要，不更新角色档案或时间线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Spacer(minLength: 4)

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
        }
        .padding(24)
        // A-2 reviewer 🟡 #8: keep minHeight modest so the sheet still fits
        // inside the K-1 minimum window (880×580). idealHeight stays larger
        // so on roomy displays the sheet still feels generous; maxHeight is
        // unset so the user can resize on macOS without the sheet clipping.
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 600)
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

        let payload = ChapterImportRequest(
            // Send the trimmed version so the backend stores clean text; we
            // still keep the user's in-sheet `draftText` untouched in case
            // they cancel and re-edit.
            draftText: trimmedDraft,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
            runExtractor: runExtractor
        )

        isSubmitting = true
        Task {
            // Snapshot bookId before the call — the chapter object inside
            // the store may be replaced by the response and we still need
            // to know which book's characters to refresh.
            let bookId = chapterEditorStore.chapter?.bookId
            let result = await chapterEditorStore.importChapter(payload)
            isSubmitting = false
            guard let result else {
                // Error already published to ErrorBus by the store. Keep the
                // sheet open so the user can fix and retry without re-pasting.
                return
            }
            // Mirror ChapterToolbar.finalize() side-effects so the rest of
            // the UI stays in sync (sidebar status pill, character highlights,
            // live_fields refresh).
            chaptersStore.upsert(result.chapter)
            charactersStore.markUpdated(result.updatedCharacterIds)
            if let bookId, !result.updatedCharacterIds.isEmpty {
                await charactersStore.load(bookId: bookId)
            }
            dismiss()
        }
    }
}
