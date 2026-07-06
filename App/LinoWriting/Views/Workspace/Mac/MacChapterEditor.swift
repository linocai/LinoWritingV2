#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — macOS workspace centre column (three-stage flow).
///
/// Handoff `LinoWriting.dc.html` 工作台 CENTER. Toolbar (章号 + StatusBadge +
/// 章名; trailing status-driven actions) over a glass-card flow (max 720,
/// centred):
///   ① 本章剧情 — `user_prompt` (a full prose account of what happens this
///      chapter, v1.3.0 JJ P7) + "优化师 · 生成本章指令" (`expand`, force when
///      prompt_ready).
///   ② 本章创作指令 (HERO) — accent-bordered Songti box bound to
///      `structured_prompt.chapter_directive`; below, "结构要点 · 供 Writer 参考"
///      with the demoted goal / scene·pov·words / must·must-not·chars·focus
///      tags. "Writer · 写正文" (SSE `write`; red "■ 停止生成" while streaming).
///   ③ 正文 — Songti paragraphs + word count; blinking caret while streaming.
///      Status-driven footer: draft_ready → finalize; finalized → 阅读模式 /
///      重新提取 / 重新打开编辑, plus the green 本章梗概 block above.
///
/// SSE write reuses `ChapterEditorStore.startWriting` / `cancelStream`. Status
/// button visibility follows the backend state machine strictly. macOS-only.
struct MacChapterEditor: View {
    let book: Book
    /// "阅读模式" entry → caller pushes the reader overlay (Phase 4 target).
    var onRead: () -> Void = {}

    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var environment: AppEnvironment

    // Editable drafts (commit on blur).
    @State private var promptDraft = ""
    @State private var directiveDraft = ""
    @State private var titleDraft = ""
    @FocusState private var promptFocused: Bool
    @FocusState private var directiveFocused: Bool

    @State private var showImportSheet = false
    @State private var showResetConfirm = false
    @State private var isExportingChapter = false

    private var chapter: Chapter? { chapterEditorStore.chapter }

    var body: some View {
        Group {
            if let chapter {
                VStack(spacing: 0) {
                    toolbar(chapter)
                    flow(chapter)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncDrafts(chapter) }
        .onChange(of: chapter?.id) { _, _ in syncDrafts(chapter) }
        .onChange(of: chapter?.userPrompt ?? "") { _, new in if !promptFocused { promptDraft = new } }
        .onChange(of: chapter?.structuredPrompt?.chapterDirective ?? "") { _, new in if !directiveFocused { directiveDraft = new } }
        .sheet(isPresented: $showImportSheet) {
            ImportChapterSheet(chapter: chapter ?? placeholderChapter)
        }
        .alert("强制重置章节状态？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("强制重置", role: .destructive) {
                Task { await chapterEditorStore.adminReset(targetStatus: .draftReady); refreshList() }
            }
        } message: {
            Text("把当前章节强制改回「草稿就绪」状态。正文与结构化提示会保留，仅清掉卡死的状态。\n\n用于章节状态卡死时自救，正常流程不要用。")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LWColor.mutedText2)
            Text("从左侧选择一章，或新建一章开始。")
                .font(.system(size: 14))
                .foregroundStyle(LWColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private func toolbar(_ chapter: Chapter) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 10) {
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LWColor.mutedText3)
                    StatusBadge(displayStatus(chapter))
                }
                TextField("未命名章节", text: $titleDraft, onCommit: commitTitle)
                    .textFieldStyle(.plain)
                    .font(LWFont.songti(18, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            Spacer(minLength: 8)

            if isFinalized(chapter) {
                LWPrimaryButton(title: "阅读模式 ›", height: 34, horizontalPadding: 15, action: onRead)
            }
            LWIconButton(systemName: "square.and.arrow.down", help: "导出本章") {
                runExportChapter(chapter)
            }
            if canImport(chapter) {
                LWIconButton(systemName: "square.and.arrow.up", help: "导入正文") { showImportSheet = true }
            }
            LWIconButton(systemName: "arrow.counterclockwise.circle", foreground: LWColor.warning, help: "强制重置（卡死时）") {
                showResetConfirm = true
            }
            LWIconButton(systemName: "trash", foreground: LWColor.danger, help: "删除章节") {
                Task { await chaptersStore.delete(id: chapter.id) }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LWColor.hex(0x282D46, opacity: 0.07)).frame(height: 0.5)
        }
    }

    // MARK: - Flow

    private func flow(_ chapter: Chapter) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    // v1.2.0 (HH) P4: a finalized chapter only shows 正文 (stage3)
                    // — steps ①本章剧情 and ②创作指令 are no longer relevant once the
                    // chapter is done, and `hasStructured` returns true for
                    // `.finalized` so stage2 used to still render here.
                    if !isFinalized(chapter) {
                        stage1(chapter)
                        if hasStructured(chapter) { stage2(chapter) }
                    }
                    if showDraftStage(chapter) { stage3(chapter).id("stage3") }
                }
                .frame(maxWidth: LWMetrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 80)
            }
            // While the Writer streams, keep the growing draft in view so the
            // author watches the text appear (and the blinking caret stays
            // on-screen) rather than having to scroll past the structure points.
            .onChange(of: chapterEditorStore.isStreaming) { _, streaming in
                if streaming {
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("stage3", anchor: .bottom) }
                }
            }
            .onChange(of: streamCharCount) { _, _ in
                if chapterEditorStore.isStreaming {
                    proxy.scrollTo("stage3", anchor: .bottom)
                }
            }
        }
    }

    /// Live token count while streaming — drives the auto-scroll onChange.
    private var streamCharCount: Int {
        if case .streaming(_, let chars) = chapterEditorStore.writingState { return chars }
        return 0
    }

    // MARK: ① 本章剧情

    private func stage1(_ chapter: Chapter) -> some View {
        stageCard {
            stageHeader(number: "1", title: "本章剧情 · 把这章发生的事完整写出来")
            LWTextArea(
                text: $promptDraft,
                placeholder: "把这一章要发生的事完整写下来（场景、人物、冲突、结局…）",
                minHeight: 220,
                font: .system(size: 14.5)
            )
            .focused($promptFocused)
            .onChange(of: promptFocused) { _, focused in if !focused { commitPrompt() } }

            if showExpandButton(chapter) {
                HStack {
                    LWAccentTintButton(
                        title: chapter.status == .promptReady ? "重新起草指令" : "优化师 · 生成本章指令",
                        systemImage: "sparkles",
                        enabled: !chapterEditorStore.isExpanding && !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) { runExpand(force: chapter.status == .promptReady) }
                    if chapterEditorStore.isExpanding {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Spacer()
                }
                .padding(.top, 14)
            }
        }
    }

    // MARK: ② HERO directive

    private func stage2(_ chapter: Chapter) -> some View {
        let sp = chapter.structuredPrompt ?? StructuredPrompt()
        return stageCard {
            HStack(spacing: 9) {
                stageBadge("2")
                Text("本章创作指令")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LWColor.bodyText)
                Spacer()
                Text("优化师起草 · 你来定稿")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LWColor.accentText)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(LWColor.accentStart.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("⚑ 这是你最该把关的一步 —— 审这段 200–300 字的方向与张力，改到满意再放行给 Writer。")
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // HERO box — accent border + pale blue fill + Songti.
            directiveBox

            LWCenteredDivider(text: "结构要点 · 供 Writer 参考")
                .padding(.top, 4)

            // 本章目标
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("本章目标")
                Text(sp.chapterGoal.isEmpty ? "—" : sp.chapterGoal)
                    .font(.system(size: 13.5))
                    .foregroundStyle(LWColor.secondaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // scene / pov / target word count
            HStack(spacing: 10) {
                infoCell(label: "场景", value: sp.sceneSetting?.nonEmpty ?? "—")
                infoCell(label: "视角", value: sp.narrativePov?.label ?? "—")
                infoCell(label: "目标字数", value: sp.targetWordCount.map { "\($0) 字" } ?? "—")
            }

            // must / must-not / chars / focus
            VStack(alignment: .leading, spacing: 12) {
                tagGroup(label: "✓ 必须发生", color: LWColor.success, items: sp.mustHappen,
                         tagFg: LWColor.hex(0x2F7A52), tagBg: LWColor.success.opacity(0.1))
                tagGroup(label: "✕ 不可发生", color: LWColor.danger, items: sp.mustNotHappen,
                         tagFg: LWColor.hex(0xB0524B), tagBg: LWColor.danger.opacity(0.1))
                HStack(alignment: .top, spacing: 20) {
                    tagGroup(label: "涉及角色", color: LWColor.mutedText3,
                             items: sp.charactersInvolved.map { characterName($0) },
                             tagFg: LWColor.secondaryText2, tagBg: LWColor.hex(0x787D96, opacity: 0.1))
                    tagGroup(label: "聚焦特质", color: LWColor.mutedText3, items: sp.focusTraits,
                             tagFg: LWColor.authorNote, tagBg: LWColor.hex(0x9A6BE0, opacity: 0.12))
                }
            }

            if showWriteButton(chapter) {
                HStack(spacing: 10) {
                    if chapterEditorStore.isStreaming {
                        LWDangerTintButton(title: "停止生成", systemImage: "stop.fill") {
                            chapterEditorStore.cancelStream()
                        }
                    } else {
                        LWPrimaryButton(
                            title: hasDraft(chapter) ? "Writer · 重新生成" : "Writer · 写正文",
                            systemImage: "pencil",
                            enabled: !(sp.chapterGoal.isEmpty && directiveDraft.isEmpty)
                        ) { startWriting() }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    private var directiveBox: some View {
        LWTextArea(
            text: $directiveDraft,
            placeholder: "优化师起草的 200–300 字本章创作指令…",
            minHeight: 132,
            font: LWFont.songti(14.5),
            lineSpacing: 6,
            background: LWColor.accentStart.opacity(0.04),
            border: LWColor.accentStart.opacity(0.32),
            borderWidth: 1,
            glow: LWColor.accentStart.opacity(0.12)
        )
        .focused($directiveFocused)
        .onChange(of: directiveFocused) { _, focused in if !focused { commitDirective() } }
    }

    // MARK: ③ 正文

    private func stage3(_ chapter: Chapter) -> some View {
        stageCard(panelOpacity: 0.7) {
            HStack(spacing: 9) {
                stageBadge("3")
                Text("正文").font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
                Text("Writer 起草 · 你读一遍定稿")
                    .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
                Spacer()
                // v1.2.0 (HH) P7: "模型思考中…" indicator only — no
                // collapsible reasoning content shown (作者拍板收窄范围).
                // Thinking text never enters draftBody/word count.
                if chapterEditorStore.isThinking {
                    thinkingIndicator
                }
                Text("\(draftWordCount(chapter)) 字")
                    .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
            }

            draftBody(chapter)

            if isFinalized(chapter), let summary = chapter.summary, !summary.isEmpty {
                summaryBlock(summary)
            }

            footerButtons(chapter)
        }
    }

    @ViewBuilder
    private func draftBody(_ chapter: Chapter) -> some View {
        let text = currentDraftText(chapter)
        let streaming = chapterEditorStore.isStreaming
        VStack(alignment: .leading, spacing: 0) {
            if text.isEmpty && !streaming {
                Text("还没有正文。回到上一步点「Writer · 写正文」。")
                    .font(LWFont.songti(15))
                    .foregroundStyle(LWColor.mutedText3)
            } else {
                ForEach(Array(paragraphs(text).enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(LWFont.songti(15.5))
                        .foregroundStyle(LWColor.hex(0x2A2C34))
                        .lineSpacing(15.5)            // line-height ~2.0
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 15.5)
                }
                if streaming {
                    BlinkingCaret()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryBlock(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LWSectionLabel("本章梗概 · 抽取生成", color: LWColor.success)
            Text(summary)
                .font(.system(size: 13.5))
                .foregroundStyle(LWColor.hex(0x3A5C47))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(LWColor.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(LWColor.success.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func footerButtons(_ chapter: Chapter) -> some View {
        HStack(spacing: 10) {
            if chapter.status == .draftReady && !chapterEditorStore.isStreaming {
                LWSuccessButton(title: "档案员 · 提取入库", systemImage: "checkmark", enabled: !chapterEditorStore.isFinalizing) {
                    finalize()
                }
            }
            if isFinalized(chapter) {
                LWPrimaryButton(title: "阅读模式 ›", action: onRead)
                LWBorderedButton(title: chapterEditorStore.isExtracting ? "提取中…" : "重新提取", systemImage: "arrow.clockwise") {
                    reExtract()
                }
                LWBorderedButton(title: "重新打开编辑", systemImage: "arrow.uturn.backward", foreground: LWColor.warning) {
                    Task { _ = await chapterEditorStore.reopen(); refreshList() }
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    /// v1.2.0 (HH) P7 — "模型思考中…" process indicator (stage3 header,
    /// only while `chapterEditorStore.isThinking`). No collapsible content,
    /// no persistence — purely a transient hint that a reasoning model is
    /// generating chain-of-thought before its first prose token arrives.
    private var thinkingIndicator: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text("模型思考中…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LWColor.mutedText3)
        }
    }

    // MARK: - Stage helpers

    @ViewBuilder
    private func stageCard<Content: View>(panelOpacity: Double = 0.62, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(panelOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.25)
                .stroke(LWColor.hex(0x282D46, opacity: 0.09), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(LinearGradient(colors: [LWMetrics.topHighlight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: LWColor.hex(0x141C3C, opacity: 0.16), radius: 14, y: 8)
    }

    private func stageHeader(number: String, title: String) -> some View {
        HStack(spacing: 9) {
            stageBadge(number)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
            Spacer()
        }
    }

    private func stageBadge(_ n: String) -> some View {
        Text(n)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LWColor.accentText)
            .frame(width: 22, height: 22)
            .background(LWColor.accentStart.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func infoCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(LWColor.mutedText3)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(LWColor.bodyText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LWColor.hex(0x787D96, opacity: 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func tagGroup(label: String, color: Color, items: [String], tagFg: Color, tagBg: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LWSectionLabel(label, color: color)
            if items.isEmpty {
                Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        LWTagChip(text: item, foreground: tagFg, background: tagBg)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - State machine predicates (strict)

    private func displayStatus(_ chapter: Chapter) -> ChapterStatus {
        chapterEditorStore.isStreaming ? .writing : chapter.status
    }
    private func isFinalized(_ chapter: Chapter) -> Bool { chapter.status == .finalized }
    private func hasDraft(_ chapter: Chapter) -> Bool {
        !(chapter.draftText ?? "").isEmpty
    }
    /// ② shown once a structured prompt exists (prompt_ready and onward).
    private func hasStructured(_ chapter: Chapter) -> Bool {
        switch chapter.status {
        case .draft: return false
        case .promptReady, .writing, .draftReady, .finalized: return true
        }
    }
    /// ③ shown while writing (streaming) or once a draft exists.
    private func showDraftStage(_ chapter: Chapter) -> Bool {
        if chapterEditorStore.isStreaming { return true }
        switch chapter.status {
        case .draft, .promptReady: return hasDraft(chapter)
        case .writing, .draftReady, .finalized: return true
        }
    }
    /// "优化师 · 生成本章指令" — visible in draft / prompt_ready (re-draft).
    private func showExpandButton(_ chapter: Chapter) -> Bool {
        switch chapter.status {
        case .draft, .promptReady: return true
        case .writing, .draftReady, .finalized: return false
        }
    }
    /// "Writer · 写正文" — visible in prompt_ready / draft_ready / writing.
    private func showWriteButton(_ chapter: Chapter) -> Bool {
        if chapterEditorStore.isStreaming { return true }
        switch chapter.status {
        case .promptReady, .draftReady: return true
        case .writing: return true
        case .draft, .finalized: return false
        }
    }
    private func canImport(_ chapter: Chapter) -> Bool {
        switch chapter.status {
        case .draft, .promptReady, .draftReady: return true
        case .writing, .finalized: return false
        }
    }

    private func currentDraftText(_ chapter: Chapter) -> String {
        if case .streaming(let buffer, _) = chapterEditorStore.writingState, !buffer.isEmpty {
            return buffer
        }
        return chapter.draftText ?? ""
    }
    private func draftWordCount(_ chapter: Chapter) -> Int {
        currentDraftText(chapter).filter { !$0.isWhitespace }.count
    }
    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private func characterName(_ id: String) -> String {
        charactersStore.characters.first(where: { $0.id == id })?.name ?? id
    }

    // MARK: - Actions

    private func syncDrafts(_ chapter: Chapter?) {
        promptDraft = chapter?.userPrompt ?? ""
        directiveDraft = chapter?.structuredPrompt?.chapterDirective ?? ""
        titleDraft = chapter?.title ?? ""
    }

    private func commitPrompt() {
        guard let chapter, promptDraft != (chapter.userPrompt ?? "") else { return }
        Task { await chapterEditorStore.patchUserPrompt(promptDraft); refreshList() }
    }
    private func commitTitle() {
        guard let chapter else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (chapter.title ?? "") else { return }
        Task { await chapterEditorStore.patchTitle(trimmed); refreshList() }
    }
    private func commitDirective() {
        guard let chapter else { return }
        let current = chapter.structuredPrompt?.chapterDirective ?? ""
        guard directiveDraft != current else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.chapterDirective = directiveDraft.isEmpty ? nil : directiveDraft
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    private func runExpand(force: Bool) {
        if promptFocused { commitPrompt() }
        Task {
            _ = await chapterEditorStore.expand(force: force)
            syncDrafts(chapterEditorStore.chapter)
            refreshList()
        }
    }

    private func startWriting() {
        if directiveFocused { commitDirective() }
        chapterEditorStore.startWriting { chapter in
            chaptersStore.upsert(chapter)
        }
    }

    private func finalize() {
        Task {
            if let result = await chapterEditorStore.finalize() {
                charactersStore.markUpdated(result.updatedCharacterIds)
                chaptersStore.upsert(result.chapter)
                await charactersStore.load(bookId: book.id)
            }
        }
    }

    private func reExtract() {
        guard !chapterEditorStore.isExtracting else { return }
        Task {
            if let result = await chapterEditorStore.extract() {
                chaptersStore.upsert(result.chapter)
                charactersStore.markUpdated(result.updatedCharacterIds)
                if !result.updatedCharacterIds.isEmpty {
                    await charactersStore.load(bookId: book.id)
                }
            }
        }
    }

    private func runExportChapter(_ chapter: Chapter) {
        guard !isExportingChapter else { return }
        isExportingChapter = true
        Task {
            defer { isExportingChapter = false }
            do {
                let (data, suggested) = try await environment.apiClient.exportChapter(id: chapter.id, format: .markdown)
                try await FileSaver.save(data: data, suggestedFilename: suggested)
            } catch let error as AppError {
                environment.errorBus.publish(error)
            } catch {
                environment.errorBus.publish(.transport(error.localizedDescription))
            }
        }
    }

    private func refreshList() {
        if let chapter = chapterEditorStore.chapter { chaptersStore.upsert(chapter) }
    }

    private var placeholderChapter: Chapter {
        Chapter(id: "", bookId: book.id, index: 0, status: .draft, createdAt: Date(), updatedAt: Date())
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
