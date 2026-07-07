import SwiftUI

public struct NewChapterSheet: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    // v1.3.1 (KK) P4: `charactersStore` (right-panel highlight after an
    // auto-extracting single-chapter import) and `environment` (direct
    // `getChapter` re-fetch to distinguish "nothing landed" from "body
    // committed, extractor failed" after a two-phase import error).
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var environment: AppEnvironment
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

    // v0.7 §5.O batch-mode state
    @State private var batchMode: Bool = false
    /// Cached splitter output — recomputed in `.onChange(of: draftText)`
    /// rather than computing on every render. Pasting 50 chapters
    /// re-runs the regex sweep on every keystroke if we don't cache,
    /// which lags the TextEditor noticeably on a 200K paste.
    @State private var parsedChapters: [ParsedChapter] = []
    /// Progress during batch submit. `(current, total)` — current is
    /// 0 before the first chapter completes, ramps to `total` at
    /// finish. `nil` means "not running" so the button reverts to its
    /// idle label.
    @State private var batchProgress: (current: Int, total: Int)?
    /// Failures collected from the batch run, surfaced via the failure
    /// sheet after `batchCreateAndImport` returns. Empty `→` everything
    /// succeeded.
    @State private var batchFailures: [BatchFailure] = []
    @State private var showFailureSheet: Bool = false

    /// One row in the post-batch failure summary sheet. Keeps the
    /// chapter title (so the user can find it in their source doc)
    /// alongside the backend's error message.
    private struct BatchFailure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // Body font follows the same preference Step3 / ImportChapterSheet
    // use (PROJECT_PLAN §5.K.4) so the paste preview matches the editor.
    @AppStorage(Settings.editorFontDesignKey) private var fontDesignRaw: String = EditorFontDesign.default.rawValue
    private var bodyFontDesign: Font.Design {
        (EditorFontDesign(rawValue: fontDesignRaw) ?? .default).fontDesign
    }

    public init() {}

    public var body: some View {
        // PROJECT_PLAN v0.9.3 §5.DI.3: header + footer are pinned OUTSIDE the
        // ScrollView so the "取消 / 提交" row is always visible regardless of
        // window height. The greedy TextEditor lives inside the scroll area;
        // a macOS sheet can't exceed its parent window (K-1 min 880×580), so
        // the old un-capped VStack pushed the footer off-screen.
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 16) {
                    // Title input is shared between create and single-chapter
                    // import, but hidden in batch mode — each chapter gets its
                    // title from the splitter (boundary line) instead.
                    if !(mode == .importing && batchMode) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("标题（可选）").font(.callout.weight(.medium))
                            TextField("例如：山洞夜话", text: $title)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSubmitting)
                        }
                    }

                    if mode == .create {
                        createFields
                    } else {
                        importFields
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }

            footer
        }
        // v0.9.x iOS fix: this fixed sheet sizing is macOS-only. On iOS the
        // sheet is presented full-width by the system; a minWidth of 520pt
        // (> iPhone width ~393pt) forced the content to overflow off both
        // edges (title / segmented picker / submit button clipped). On iOS we
        // set no explicit size — the ScrollView + pinned footer fill the sheet.
        #if os(macOS)
        .frame(
            minWidth: 520,
            idealWidth: 580,
            minHeight: 440,
            idealHeight: idealHeight,
            maxHeight: 560
        )
        #endif
        .sheet(isPresented: $showFailureSheet) {
            batchFailureSheet
        }
        // Recompute splitter preview whenever the user pastes / types
        // into the textarea — but only in batch mode, since single-chapter
        // mode never reads `parsedChapters`. Throttling isn't necessary
        // here: TextEditor's onChange already coalesces character-by-
        // character typing into the runloop, and the splitter on a 50-
        // chapter paste takes well under 10ms on M1.
        .onChange(of: draftText) { _, newValue in
            guard mode == .importing, batchMode else { return }
            parsedChapters = ChapterSplitter.split(newValue)
        }
        .onChange(of: batchMode) { _, isOn in
            // Recompute (or clear) preview when the user flips the toggle
            // so switching from single→batch with text already pasted
            // doesn't show a stale "0 chapters" hint.
            parsedChapters = isOn ? ChapterSplitter.split(draftText) : []
        }
    }

    private var idealHeight: CGFloat {
        switch mode {
        case .create: return 560
        case .importing: return batchMode ? 560 : 540
        }
    }

    // MARK: Pinned header / footer (stay visible while the form scrolls)

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 16) {
            Text("新建章节")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var footer: some View {
        Divider()
        HStack {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
            Spacer()
            Button(action: submit) {
                submitButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSubmitting || !canSubmit)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    // MARK: Submit button label

    @ViewBuilder
    private var submitButtonLabel: some View {
        if let p = batchProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("导入中 \(p.current)/\(p.total) …")
            }
        } else if isSubmitting {
            ProgressView().controlSize(.small)
        } else {
            Text(submitButtonText)
        }
    }

    private var submitButtonText: String {
        switch mode {
        case .create: return "创建"
        case .importing:
            if batchMode {
                return parsedChapters.isEmpty ? "批量导入" : "批量导入 \(parsedChapters.count) 章"
            }
            return "导入"
        }
    }

    // MARK: Create-mode fields

    @ViewBuilder
    private var createFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本章剧情 · 完整写出这章发生的事").font(.callout.weight(.medium))
            TextEditor(text: $prompt)
                .frame(height: 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            Text("\(prompt.count) 字")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Import-mode fields

    @ViewBuilder
    private var importFields: some View {
        // Batch toggle + (when on) separator hint
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $batchMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量模式").font(.callout)
                    Text("一次贴入多章原稿，系统自动切分")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(isSubmitting)

            if batchMode {
                Text("系统会按 `第X章` / `Chapter X` / `===` / `---` 之类的分隔符切分章节。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("正文").font(.callout.weight(.medium))
            TextEditor(text: $draftText)
                .font(.system(.body, design: bodyFontDesign))
                .lineSpacing(4)
                .frame(minHeight: batchMode ? 180 : 220, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .overlay(alignment: .topLeading) {
                    // Placeholder text inside the empty editor — SwiftUI's
                    // TextEditor has no first-class placeholder, so we
                    // hand-roll one that only shows when the buffer is empty.
                    if draftText.isEmpty {
                        Text(batchMode ? "粘贴含多章的完整文本" : "粘贴单章正文")
                            .font(.system(.body, design: bodyFontDesign))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.top, 16)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }
        }

        if batchMode {
            batchPreview
        } else {
            // Single-chapter mode keeps the legacy fields.
            VStack(alignment: .leading, spacing: 6) {
                Text("章节摘要（可选）").font(.callout.weight(.medium))
                TextField("留空交给 Agent 提取", text: $summary, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
            }
        }

        // v1.3.1 (KK) P4: single-chapter import now auto-runs the Extractor
        // (author's decision — 推翻 v0.9.3 §5.DI's "import 只落正文,提取纯手动").
        // Batch import still only lands the body per chapter (a串行 N-chapter
        // batch ×300s extraction each isn't viable, and a partial-failure
        // skeleton semantics would get confusing) — so the hint text differs
        // by mode; the manual "提取角色/时间线" button still exists on both
        // paths (finalized 态可重跑) for the batch case / re-runs.
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            if batchMode {
                Text("批量导入只保存正文；导入后可逐章手动点「提取角色/时间线」更新角色卡 / 时间线。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("导入后将自动提取角色 / 时间线；若解析失败，正文仍会保留，可在工具栏重新提取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Batch preview

    @ViewBuilder
    private var batchPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if parsedChapters.isEmpty {
                    Text("检测到 0 个章节")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // Material chip mirrors the §5.K.4 visual language.
                    Text("检测到 ")
                        .font(.callout) +
                    Text("\(parsedChapters.count)")
                        .font(.callout.weight(.semibold)) +
                    Text(" 个章节")
                        .font(.callout)
                }
                Spacer()
                if parsedChapters.count == 1 && !draftText.isEmpty {
                    // Make the fallback-to-single-chapter case visible
                    // so the user understands why batch shows "1".
                    Text("未检测到分隔符，将作为单章导入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !parsedChapters.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(parsedChapters) { ch in
                            HStack(spacing: 8) {
                                Text("第 \(ch.index + 1) 章")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                Text(ch.title ?? "（无标题）")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text("\(ch.characterCount) 字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
    }

    // MARK: Failure summary sheet

    @ViewBuilder
    private var batchFailureSheet: some View {
        VStack(spacing: 16) {
            Text("部分章节导入失败")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(batchFailures.count) / \(batchProgress?.total ?? batchFailures.count) 章未能导入：")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(batchFailures) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title)
                                .font(.callout.weight(.medium))
                            Text(f.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("知道了") {
                    showFailureSheet = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    // MARK: Submit gating

    private var canSubmit: Bool {
        switch mode {
        case .create:
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importing:
            if batchMode {
                // Need at least one parsed chapter — `parsedChapters`
                // is empty when `draftText` is empty.
                return !parsedChapters.isEmpty
            }
            return !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Submit

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
                if batchMode {
                    await submitBatch()
                } else {
                    await submitImport(title: titleValue)
                }
            }
            isSubmitting = false
        }
    }

    /// Two-step submit: create an empty chapter (user_prompt = ""), then
    /// call the import endpoint on it. Both steps share the chapter
    /// store's error-bus plumbing, so any failure surfaces as a Toast
    /// without dismissing this sheet — the user can fix and retry.
    private func submitImport(title: String?) async {
        // PROJECT_PLAN v0.9.3 §5.DI: trim the body so leading/trailing
        // clipboard whitespace doesn't land in storage, and guard against an
        // all-whitespace paste sneaking past the trimmed `canSubmit` gate.
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }

        // Step 1: create skeleton chapter. user_prompt is sent as "" since
        // the backend ChapterCreate schema requires a string but a
        // chapter sourced from import won't be running the Agent against
        // that prompt anyway. (Backend chapter row keeps the empty value.)
        guard let new = await chaptersStore.create(userPrompt: "", title: title) else { return }

        // Step 2: set it as the active editor target so importChapter's
        // self.chapter check passes, then drive the import.
        // v1.3.1 (KK) P4: single-chapter import now runs the Extractor
        // (author's decision — 推翻 v0.9.3 §5.DI "import 只落正文,提取纯手动").
        // The backend's import endpoint is two-phase for this path: body +
        // finalized status commit first, extraction is a second transaction
        // that only rolls back its own output on LLM failure — the draft
        // text is never lost even if extraction errors upstream.
        await chapterEditorStore.load(chapterId: new.id)
        let payload = ChapterImportRequest(
            draftText: trimmedDraft,
            title: title,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary,
            runExtractor: true
        )
        if let result = await chapterEditorStore.importChapter(payload) {
            // Step 3: sync the sidebar list (the row we just appended is
            // still in draft state; the import response has it as
            // finalized / source=imported).
            chaptersStore.upsert(result.chapter)
            charactersStore.markUpdated(result.updatedCharacterIds)
            if !result.updatedCharacterIds.isEmpty {
                await charactersStore.load(bookId: result.chapter.bookId)
            }
            dismiss()
        } else {
            // v1.3.1 (KK) P4: with `runExtractor: true`, the backend's import
            // endpoint is two-phase — body/title/source/finalized commits in
            // its own transaction FIRST, then extraction runs in a second
            // transaction whose failure only rolls back the extraction
            // output (see PROJECT_PLAN §4 P4). So a thrown error here can now
            // mean "body committed fine, but the Extractor round-trip failed
            // upstream" — NOT just a transport failure before anything
            // landed, unlike the old §5.DI-era single-phase
            // always-run_extractor=false behavior this branch was written
            // for. Re-GET the skeleton chapter to find out which case this
            // is before deciding whether it's safe to delete it.
            //
            // v1.3.1 (KK) 审后修复 🟡#3: the original two-way check treated
            // "GET failed" the same as "confirmed not landed" and deleted
            // the chapter either way. But GET-failed ≠ not-landed — the
            // import request may have reached the backend and committed
            // phase-1 while the *response* (or this follow-up GET) was lost
            // to a network blip; that combination would delete a
            // finalized chapter with real prose in it. Three states now:
            //   1. GET succeeds, confirmed finalized+non-empty → landed, keep.
            //   2. GET succeeds, confirmed not finalized/empty → not landed, delete.
            //   3. GET itself fails → unknown, don't delete either way.
            do {
                let reloaded = try await environment.apiClient.getChapter(id: new.id)
                if reloaded.status == .finalized, !(reloaded.draftText ?? "").isEmpty {
                    // State 1 — body committed; only the extractor step
                    // failed upstream. Keep the now-finalized chapter, sync
                    // the sidebar, and let the author retry extraction
                    // manually from the editor.
                    chaptersStore.upsert(reloaded)
                    await chapterEditorStore.load(chapterId: new.id)
                    dismiss()
                } else {
                    // State 2 — confirmed nothing usable landed. Safe to
                    // delete + let the author retry with their pasted body
                    // still in the textarea.
                    await chaptersStore.delete(id: new.id)
                    chapterEditorStore.reset()
                }
            } catch {
                // State 3 — inconclusive. Do NOT delete (might be a
                // finalized chapter with real prose we just can't see right
                // now); do NOT silently keep editing either (the skeleton
                // may or may not still be the "current" editor target).
                // Surface a distinct notice so the author knows to check
                // back rather than assuming the earlier upstream-error
                // Toast was the whole story, and leave the sheet + the
                // skeleton chapter alone for a manual follow-up.
                environment.errorBus.publish(
                    "无法确认这一章的导入结果（网络问题），请稍后在章节列表里确认状态，不要重复导入。",
                    critical: false
                )
            }
        }
        // On failure ErrorBus already published; keep sheet open for retry
        // only in the "not landed" / "inconclusive" branches above.
    }

    /// Batch import path (v0.7 §5.O). Drives `ChaptersStore.batchCreateAndImport`,
    /// updating `batchProgress` after each chapter so the button label
    /// shows "导入中 N/M …" in real time. After the run completes:
    ///   - all-success → dismiss with no extra UI; the sidebar already
    ///     grew during the run so the user sees the result there
    ///   - any failure → present the failure summary sheet so the user
    ///     can see which chapters didn't land and why
    ///   - all-failure → publish to ErrorBus + keep the sheet open
    ///     (transport / unauthorized at the very first chapter usually
    ///     means a misconfigured backend — telling the user to "fix and
    ///     retry" is better than a sheet of identical error rows)
    private func submitBatch() async {
        let chapters = parsedChapters
        guard !chapters.isEmpty else { return }
        batchProgress = (current: 0, total: chapters.count)
        batchFailures = []

        // v1.3.1 (KK) P4: batch import deliberately keeps `run_extractor:
        // false` even though single-chapter import (`submitImport` above) now
        // defaults to `true`. Reasons this stays manual for batch: a
        //串行 N-chapter run at up to 300s/chapter for a thinking-model
        // extraction isn't viable UX for large pastes, and mixing
        // partial-extraction-failure semantics into the batch progress/
        // failure-summary UI would get confusing. Extraction stays a
        // separate manual per-chapter step (工具栏「提取角色/时间线」),
        // so there's no end-of-batch character-store refresh here.
        let results = await chaptersStore.batchCreateAndImport(
            parsedChapters: chapters,
            runExtractor: false,
            progress: { current, total in
                batchProgress = (current: current, total: total)
            }
        )

        // Aggregate failures with their source titles so the failure
        // sheet can show "第 N 章 · 标题 — message".
        var failures: [BatchFailure] = []
        for (idx, outcome) in results.enumerated() {
            let title = chapters[safe: idx]?.title ?? "（无标题）"
            switch outcome {
            case .success:
                break
            case .failure(let error):
                failures.append(BatchFailure(
                    title: "第 \(idx + 1) 章 · \(title)",
                    message: error.message
                ))
            }
        }

        batchFailures = failures
        if failures.isEmpty {
            // All success → close.
            batchProgress = nil
            dismiss()
        } else if failures.count == chapters.count {
            // All failed → keep sheet open, surface to bus.
            batchProgress = nil
            chaptersStore.errorBusPublishFromBatch(
                "批量导入失败：所有 \(chapters.count) 章均未导入，请检查后端 / 网络后重试"
            )
        } else {
            // Partial → show the summary sheet.
            showFailureSheet = true
        }
    }
}

// MARK: - Safe index helper

private extension Array {
    subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}
