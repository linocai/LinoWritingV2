import SwiftUI

public struct ChapterToolbar: View {
    let chapter: Chapter
    /// Owner (ChapterEditorView) flips this to true when the user taps
    /// "导入文本". The sheet is hosted on the parent so it survives toolbar
    /// re-renders triggered by `chapter.status` changes mid-import.
    let onImportTap: () -> Void

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    /// v0.7 §5.F — needed by "导出本章" in the overflow menu so the
    /// toolbar can hit ``APIClient.exportChapter`` + ``FileSaver`` without
    /// piping every export through a store (no shared model state).
    @EnvironmentObject var environment: AppEnvironment

    @State private var titleDraft: String
    /// Drives the §5.P.1 E "force-reset" confirmation alert. Owned here
    /// rather than on the parent because the menu trigger and the alert
    /// share the same lifetime as the toolbar itself, and the alert
    /// content doesn't need to survive toolbar rebuilds the way the
    /// import sheet does.
    @State private var showResetConfirm: Bool = false
    /// True while ``runExportChapter`` is awaiting the network /
    /// NSSavePanel. Disables the menu item to prevent double-clicks
    /// firing two downloads.
    @State private var isExportingChapter: Bool = false

    public init(chapter: Chapter, onImportTap: @escaping () -> Void = {}) {
        self.chapter = chapter
        self.onImportTap = onImportTap
        _titleDraft = State(initialValue: chapter.title ?? "")
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text("第 \(chapter.index) 章")
                .font(.headline)
            TextField("章节标题（可选）", text: $titleDraft, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.title3)
                .frame(maxWidth: 360)
                .onChange(of: chapter.title ?? "") { _, new in titleDraft = new }
            StatusBadge(chapter.status)
            Spacer()
            // PROJECT_PLAN §5.A.6 / §5.A.7: "导入文本" sits parallel to
            // "展开提纲" / "写作" etc. Hidden in `writing` (SSE race per A-1
            // reviewer) and `finalized` (chapter immutable). Visible in
            // draft / prompt_ready / draft_ready — the backend white-list.
            if canImport {
                Button(action: onImportTap) {
                    Label("导入文本", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(chapterEditorStore.isImporting)
                .help("把已写好的章节正文导入并落地为已完成章节；之后可点「提取角色/时间线」更新角色卡 / 时间线")
            }
            primaryActionButtons
            moreMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        // PROJECT_PLAN v0.7 §5.P.1 E — confirm before triggering the
        // admin_reset escape hatch. Wording is deliberately author-facing
        // (no "admin"/"reset" English jargon) and spells out exactly what
        // survives the rescue (draft_text / structured_prompt) so the
        // user isn't worried about losing work.
        .alert("强制重置章节状态？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("强制重置", role: .destructive) {
                Task { await chapterEditorStore.adminReset(targetStatus: .draftReady) }
            }
        } message: {
            Text("把当前章节强制改回「正文完成」状态。\n正文（draft_text）和结构化提示（structured_prompt）会保留，仅清掉写作中状态。\n\n用于章节状态卡死时自救，正常流程不要用。")
        }
    }

    /// Hidden "更多" menu — hosts the §5.P.1 E escape hatch + the §5.F
    /// per-chapter export action. Lives on the trailing edge of the
    /// toolbar (after the primary action buttons) so it's findable but
    /// doesn't compete with the main flow. Available in every chapter
    /// status, including `writing` and `finalized`, because both menu
    /// items are escape-hatch / out-of-band actions.
    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            Button {
                runExportChapter()
            } label: {
                Label("导出本章", systemImage: "square.and.arrow.up")
            }
            .disabled(isExportingChapter)
            Divider()
            Button {
                showResetConfirm = true
            } label: {
                Label("强制重置状态", systemImage: "exclamationmark.arrow.circlepath")
            }
            // P-2 reviewer 🟡 #2: while an admin_reset is in flight the
            // menu item is disabled so the user can't fire a second
            // redundant request (backend is idempotent, but UX should
            // still convey "in progress").
            .disabled(chapterEditorStore.isAdminResetting)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
    }

    /// v0.7 §5.F — fetch the chapter export from the backend and hand
    /// it to ``FileSaver``. Defaults to Markdown (matches the book-card
    /// flow on the shelf so the user gets a consistent experience).
    private func runExportChapter() {
        guard !isExportingChapter else { return }
        isExportingChapter = true
        Task {
            defer { isExportingChapter = false }
            do {
                let (data, suggested) = try await environment.apiClient.exportChapter(
                    id: chapter.id,
                    format: .markdown
                )
                try await FileSaver.save(data: data, suggestedFilename: suggested)
            } catch let error as AppError {
                environment.errorBus.publish(error)
            } catch {
                environment.errorBus.publish(.transport(error.localizedDescription))
            }
        }
    }

    /// Whitelist mirrors the backend's `ensure_chapter_status` set
    /// in `POST /chapters/{id}/import` — see PROJECT_PLAN §5.A.4.
    private var canImport: Bool {
        switch chapter.status {
        case .draft, .promptReady, .draftReady: return true
        case .writing, .finalized: return false
        }
    }

    @ViewBuilder
    private var primaryActionButtons: some View {
        // SSE in flight overrides the status-based switch: the local
        // chapter.status can lag the backend by a few hundred ms (it only
        // flips to .writing when the first stream event lands), and during
        // that window the .promptReady branch was still rendering the
        // enabled "写作" button — letting impatient double-clicks fire a
        // second POST /write that the backend then 409s on. Treat any
        // running stream as authoritative.
        if chapterEditorStore.isStreaming {
            Button {
                chapterEditorStore.cancelStream()
            } label: {
                Label("取消写作", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
        } else {
            statusBasedButtons
        }
    }

    @ViewBuilder
    private var statusBasedButtons: some View {
        switch chapter.status {
        case .draft:
            Button(action: expand) {
                Label("展开提纲", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(chapterEditorStore.isExpanding || (chapter.userPrompt ?? "").isEmpty)
        case .promptReady:
            HStack(spacing: 6) {
                Button {
                    Task { _ = await chapterEditorStore.expand(force: true); refreshList() }
                } label: {
                    Label("重新展开", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button(action: startWriting) {
                    Label("写作", systemImage: "pencil.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chapter.structuredPrompt?.chapterGoal.isEmpty != false)
            }
        case .writing:
            Button {
                chapterEditorStore.cancelStream()
            } label: {
                Label("取消写作", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
        case .draftReady:
            HStack(spacing: 6) {
                Button(action: startWriting) {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button(action: finalize) {
                    Label("完成", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chapterEditorStore.isFinalizing)
            }
        case .finalized:
            HStack(spacing: 6) {
                // PROJECT_PLAN v0.9.3 §5.DI.3: manual "提取角色/时间线" sits
                // parallel to "重新打开". Visible on ANY finalized chapter so
                // the author can re-extract on demand (backend clears this
                // chapter's old timeline first → repeatable, idempotent).
                Button(action: extract) {
                    if chapterEditorStore.isExtracting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("提取中…")
                        }
                    } else {
                        Label("提取角色/时间线", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(chapterEditorStore.isExtracting)
                .help("重新跑一次提取：更新角色卡 / 时间线（不改动正文与章节状态）")
                Button {
                    Task { _ = await chapterEditorStore.reopen(); refreshList() }
                } label: {
                    Label("重新打开", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        if trimmed != (chapter.title ?? "") {
            Task { await chapterEditorStore.patchTitle(trimmed); refreshList() }
        }
    }

    private func expand() {
        Task {
            _ = await chapterEditorStore.expand()
            refreshList()
        }
    }

    private func startWriting() {
        chapterEditorStore.startWriting { chapter in
            chaptersStore.upsert(chapter)
        }
    }

    private func finalize() {
        Task {
            if let result = await chapterEditorStore.finalize() {
                charactersStore.markUpdated(result.updatedCharacterIds)
                chaptersStore.upsert(result.chapter)
                // Refresh characters so live_fields are current.
                if let bookId = chapterEditorStore.chapter?.bookId {
                    await charactersStore.load(bookId: bookId)
                }
            }
        }
    }

    /// PROJECT_PLAN v0.9.3 §5.DI.3 — manual re-extract. Mirrors `finalize`'s
    /// fan-out so the right panel highlights touched cards and the character
    /// store reloads live_fields. The chapter row itself doesn't change
    /// status, but we still `upsert` so the summary list stays consistent.
    private func extract() {
        Task {
            if let result = await chapterEditorStore.extract() {
                chaptersStore.upsert(result.chapter)
                charactersStore.markUpdated(result.updatedCharacterIds)
                if !result.updatedCharacterIds.isEmpty,
                   let bookId = chapterEditorStore.chapter?.bookId {
                    await charactersStore.load(bookId: bookId)
                }
            }
        }
    }

    private func refreshList() {
        if let chapter = chapterEditorStore.chapter {
            chaptersStore.upsert(chapter)
        }
    }
}
