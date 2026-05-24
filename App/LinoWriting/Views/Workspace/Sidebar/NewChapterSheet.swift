import SwiftUI

public struct NewChapterSheet: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    /// Mode tab — v0.6.1 follow-up after A-2 user feedback: the
    /// "导入文本" entry point was buried behind ChapterToolbar, which
    /// required filling in a chapter prompt first just to reveal it.
    /// Offering the choice here removes one entire forced step.
    public enum Mode: String, CaseIterable, Identifiable {
        case create
        case importing

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .create: return "新建（让 Agent 写）"
            case .importing: return "导入（贴已有原稿）"
            }
        }
    }

    @State private var mode: Mode = .create
    @State private var title: String = ""
    @State private var isSubmitting: Bool = false

    // create-mode field
    @State private var prompt: String = ""

    // import-mode fields
    @State private var draftText: String = ""
    @State private var summary: String = ""
    @State private var runExtractor: Bool = true

    // Body font follows the same preference Step3 / ImportChapterSheet
    // use (PROJECT_PLAN §5.K.4) so the paste preview matches the editor.
    @AppStorage(Settings.editorFontDesignKey) private var fontDesignRaw: String = EditorFontDesign.default.rawValue
    private var bodyFontDesign: Font.Design {
        (EditorFontDesign(rawValue: fontDesignRaw) ?? .default).fontDesign
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Text("新建章节")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)

            VStack(alignment: .leading, spacing: 6) {
                Text("标题（可选）").font(.callout.weight(.medium))
                TextField("例如：山洞夜话", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }

            if mode == .create {
                createFields
            } else {
                importFields
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Spacer()
                Button(action: submit) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    else { Text(mode == .create ? "创建" : "导入") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(28)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: mode == .create ? 460 : 560)
    }

    @ViewBuilder
    private var createFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("章节想法（约 50 字）").font(.callout.weight(.medium))
            TextEditor(text: $prompt)
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            Text("\(prompt.count) 字")
                .font(.caption)
                .foregroundStyle(prompt.count > 200 ? .orange : .secondary)
        }
    }

    @ViewBuilder
    private var importFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("正文").font(.callout.weight(.medium))
            TextEditor(text: $draftText)
                .font(.system(.body, design: bodyFontDesign))
                .lineSpacing(4)
                .frame(minHeight: 220, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("章节摘要（可选）").font(.callout.weight(.medium))
            TextField("留空交给 Agent 提取", text: $summary, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)
        }

        Toggle(isOn: $runExtractor) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入后让 Agent 提取角色更新和时间线")
                    .font(.callout)
                Text("关闭则只落正文，不更新角色卡 / 时间线 / 摘要")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private var canSubmit: Bool {
        switch mode {
        case .create:
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importing:
            return !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() {
        isSubmitting = true
        let titleValue = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        Task {
            switch mode {
            case .create:
                let promptValue = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : prompt
                if let chapter = await chaptersStore.create(userPrompt: promptValue, title: titleValue) {
                    await chapterEditorStore.load(chapterId: chapter.id)
                    dismiss()
                }
            case .importing:
                await submitImport(title: titleValue)
            }
            isSubmitting = false
        }
    }

    /// Two-step submit: create an empty chapter (user_prompt = ""), then
    /// call the import endpoint on it. Both steps share the chapter
    /// store's error-bus plumbing, so any failure surfaces as a Toast
    /// without dismissing this sheet — the user can fix and retry.
    private func submitImport(title: String?) async {
        // Step 1: create skeleton chapter. user_prompt is sent as "" since
        // the backend ChapterCreate schema requires a string but a
        // chapter sourced from import won't be running the Agent against
        // that prompt anyway. (Backend chapter row keeps the empty value.)
        guard let new = await chaptersStore.create(userPrompt: "", title: title) else { return }

        // Step 2: set it as the active editor target so importChapter's
        // self.chapter check passes, then drive the import.
        await chapterEditorStore.load(chapterId: new.id)
        let payload = ChapterImportRequest(
            draftText: draftText,
            title: title,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary,
            runExtractor: runExtractor
        )
        if let result = await chapterEditorStore.importChapter(payload) {
            // Step 3: sync the sidebar list (the row we just appended is
            // still in draft state; the import response has it as
            // finalized / source=imported).
            chaptersStore.upsert(result.chapter)
            // Refresh characters so any live_fields the Extractor wrote
            // show up in the right panel immediately.
            if runExtractor, !result.updatedCharacterIds.isEmpty {
                await charactersStore.load(bookId: new.bookId)
            }
            dismiss()
        }
        // On failure ErrorBus already published; keep sheet open for retry.
    }
}
