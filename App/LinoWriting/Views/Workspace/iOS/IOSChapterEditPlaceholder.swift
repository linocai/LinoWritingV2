#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P4) — the iPhone three-step chapter editor.
///
/// Pushed by `IOSChaptersSection`'s destination-based `NavigationLink` (the
/// push seam P3 stood up; the type name is kept so that link is untouched).
/// Pixel-exact transcription of the handoff (`LinoWriting iOS.dc.html` 屏3 /
/// README §3.章节编辑), reflowed for iPhone full width:
///   - glass nav bar: ‹ 返回 + centred (章号 + status chip / Songti 章名) + ···
///     menu (导入文本 `POST .../import` / 导出本章 `GET .../export` / 强制重置状态
///     `POST .../admin_reset`); finalized 章 gets a top "阅读模式 ›" button.
///   - ① 本章剧情 (v1.3.0 JJ P7: full prose, not a one-liner): `user_prompt`
///     textarea + 展开提纲 (draft) / 重新展开 (prompt_ready, force) →
///     `POST .../expand`.
///   - ② 结构化提示: HERO 本章创作指令 (accent box, `chapter_directive`) + 结构
///     要点 tags; 写作 (prompt_ready)/重新生成 (draft_ready) → `POST .../write`
///     (SSE); 取消写作 while streaming.
///   - ③ 正文: Songti paragraphs + **streaming 逐字 + 闪烁光标**; finalized 绿色
///     本章梗概 block. Footer: draft_ready→完成 `POST .../finalize`;
///     finalized→提取角色/时间线 `POST .../extract` + 重新打开 `POST .../reopen`.
///
/// SSE reuses `ChapterEditorStore.startWriting` / `cancelStream` / `writingState`
/// (same store macOS `MacChapterEditor` drives); status-driven button visibility
/// follows the backend state machine strictly; a `ScrollViewReader` auto-scrolls
/// the growing draft into view while streaming. Inline edits commit on blur
/// (`PATCH /chapters/{id}`). The reader entry calls `appStore.openReader` (P5
/// wires the `.fullScreenCover`). iOS-only; macOS keeps `MacChapterEditor`.
struct IOSChapterEditPlaceholder: View {
    let chapterId: String
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var timelineStore: TimelineStore

    // Editable drafts (commit on blur).
    @State private var promptDraft = ""
    @State private var directiveDraft = ""
    @FocusState private var promptFocused: Bool
    @FocusState private var directiveFocused: Bool

    @State private var showImportSheet = false
    @State private var showResetConfirm = false
    @State private var isExportingChapter = false

    private var chapter: Chapter? { chapterEditorStore.chapter }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            flow
        }
        .background(LWColor.hex(0xEEF0F7).ignoresSafeArea())
        .navigationBarHidden(true)
        .task(id: chapterId) {
            chaptersStore.selectedChapterId = chapterId
            await chapterEditorStore.load(chapterId: chapterId)
            syncDrafts(chapterEditorStore.chapter)
            updateTimelineSelection()
        }
        .onChange(of: chapter?.userPrompt ?? "") { _, new in if !promptFocused { promptDraft = new } }
        .onChange(of: chapter?.structuredPrompt?.chapterDirective ?? "") { _, new in if !directiveFocused { directiveDraft = new } }
        .sheet(isPresented: $showImportSheet) {
            if let chapter { IOSChapterImportSheet(chapter: chapter) }
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

    // MARK: - Glass nav bar (‹ 返回 + centred title + ··· menu)

    private var navBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(LWColor.accentText)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
            chapterHeader
            Spacer(minLength: 0)

            menu
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(
            // rgba(238,240,247,0.8) + blur — matches the handoff nav glass.
            LWColor.hex(0xEEF0F7, opacity: 0.8)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(LWColor.hex(0x282D46, opacity: 0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var chapterHeader: some View {
        if let chapter {
            VStack(spacing: 1) {
                HStack(spacing: 8) {
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LWColor.mutedText3)
                    IOSStatusChip(status: displayStatus(chapter))
                }
                Text(chapter.title?.nonEmptyOr("未命名") ?? "未命名")
                    .font(LWFont.songti(16, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                    .lineLimit(1)
            }
        }
    }

    private var menu: some View {
        Menu {
            if let chapter {
                if canImport(chapter) {
                    Button { showImportSheet = true } label: {
                        Label("导入文本", systemImage: "square.and.arrow.down")
                    }
                }
                Button {
                    runExportChapter(chapter)
                } label: {
                    Label("导出本章", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label("强制重置状态", systemImage: "exclamationmark.arrow.circlepath")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LWColor.hex(0x4A4D58))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5))
        }
    }

    // MARK: - Flow

    @ViewBuilder
    private var flow: some View {
        if let chapter {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if isFinalized(chapter) { readerButton }
                        // v1.2.0 (HH) P4: a finalized chapter only shows 正文
                        // (stage3) — steps ①本章剧情 and ②结构化提示 are no longer
                        // relevant once the chapter is done (mirrors
                        // MacChapterEditor.flow).
                        if !isFinalized(chapter) {
                            stage1(chapter)
                            if hasStructured(chapter) { stage2(chapter) }
                        }
                        if showDraftStage(chapter) { stage3(chapter).id("stage3") }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 44)
                }
                // Keep the growing draft (and blinking caret) in view while the
                // Writer streams — the CLAUDE.md auto-scroll fix so streaming is
                // both visible to the author and screenshottable.
                .onChange(of: chapterEditorStore.isStreaming) { _, streaming in
                    if streaming { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("stage3", anchor: .bottom) } }
                }
                .onChange(of: streamCharCount) { _, _ in
                    if chapterEditorStore.isStreaming { proxy.scrollTo("stage3", anchor: .bottom) }
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在载入章节…")
                .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readerButton: some View {
        Button { appStore.openReader(chapterId: chapterId) } label: {
            Text("阅读模式 ›")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(LWColor.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5).blendMode(.overlay)
                )
                .shadow(color: LWColor.accentStop.opacity(0.55), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - ① 本章剧情

    private func stage1(_ chapter: Chapter) -> some View {
        stageCard {
            HStack(spacing: 9) {
                stageBadge("1")
                Text("本章剧情").font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
                Spacer()
            }
            Text("把这章发生的事完整写出来")
                .font(.system(size: 11.5)).foregroundStyle(LWColor.mutedText3).lineSpacing(2)

            LWTextArea(
                text: $promptDraft,
                placeholder: "把这一章要发生的事完整写下来（场景、人物、冲突、结局…）",
                minHeight: 220,
                font: .system(size: 14.5),
                lineSpacing: 5,
                background: LWColor.hex(0xFCFCFE, opacity: 0.8)
            )
            .focused($promptFocused)
            .onChange(of: promptFocused) { _, focused in if !focused { commitPrompt() } }

            if showExpandButton(chapter) {
                Button { runExpand(force: chapter.status == .promptReady) } label: {
                    HStack(spacing: 6) {
                        if chapterEditorStore.isExpanding {
                            ProgressView().controlSize(.small)
                        }
                        Text(chapter.structuredPrompt == nil ? "展开提纲" : "重新展开")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(LWColor.accentText)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(LWColor.accentStart.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.accentStart.opacity(0.25), lineWidth: 0.5))
                    .opacity(expandEnabled ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!expandEnabled)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - ② HERO directive + 结构要点

    private func stage2(_ chapter: Chapter) -> some View {
        let sp = chapter.structuredPrompt ?? StructuredPrompt()
        return stageCard {
            HStack(spacing: 9) {
                stageBadge("2")
                Text("结构化提示").font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
                Spacer()
            }
            Text("Agent 扩写出来的剧本骨架，可随时调整")
                .font(.system(size: 11.5)).foregroundStyle(LWColor.mutedText3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // HERO 本章创作指令
            Text("本章创作指令")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(LWColor.accentText)
            Text("⚑ 你最该把关的一步 · 优化师产出 200–300 字「方向盘」，不塞知识；审到满意再放行写作。")
                .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            LWTextArea(
                text: $directiveDraft,
                placeholder: "优化师起草的 200–300 字本章创作指令…",
                minHeight: 150,
                font: LWFont.songti(15),
                lineSpacing: 8,
                background: LWColor.accentStart.opacity(0.04),
                border: LWColor.accentStart.opacity(0.32),
                borderWidth: 1,
                glow: LWColor.accentStart.opacity(0.12)
            )
            .focused($directiveFocused)
            .onChange(of: directiveFocused) { _, focused in if !focused { commitDirective() } }

            Text("\(directiveDraft.count) 字 · 这是「方向」线；人物卡 / 时间线是另一条「知识」线直达 Writer。")
                .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
                .frame(maxWidth: .infinity, alignment: .leading)

            LWCenteredDivider(text: "结构要点 · 供 Writer 参考").padding(.vertical, 2)

            // 本章目标
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("本章目标")
                Text(sp.chapterGoal.isEmpty ? "—" : sp.chapterGoal)
                    .font(.system(size: 13.5)).foregroundStyle(LWColor.secondaryText).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 场景 / 视角 / 字数 (3-up)
            HStack(spacing: 8) {
                infoCell(label: "场景", value: sp.sceneSetting?.nonEmptyValue ?? "—")
                infoCell(label: "视角", value: sp.narrativePov?.label ?? "未定")
                infoCell(label: "字数", value: sp.targetWordCount.map { "\($0) 字" } ?? "不限")
            }

            VStack(alignment: .leading, spacing: 12) {
                tagGroup(label: "必须发生", color: LWColor.success, items: sp.mustHappen,
                         tagFg: LWColor.hex(0x2F7A52), tagBg: LWColor.success.opacity(0.1))
                tagGroup(label: "禁止发生", color: LWColor.danger, items: sp.mustNotHappen,
                         tagFg: LWColor.hex(0xB0524B), tagBg: LWColor.danger.opacity(0.1))
                HStack(alignment: .top, spacing: 18) {
                    tagGroup(label: "出场角色", color: LWColor.mutedText3,
                             items: sp.charactersInvolved.map { characterName($0) },
                             tagFg: LWColor.secondaryText2, tagBg: LWColor.hex(0x787D96, opacity: 0.1))
                    tagGroup(label: "本章人格重点", color: LWColor.mutedText3, items: sp.focusTraits,
                             tagFg: LWColor.authorNote, tagBg: LWColor.hex(0x9A6BE0, opacity: 0.12))
                }
            }

            if showWriteButton(chapter) {
                HStack(spacing: 10) {
                    if chapterEditorStore.isStreaming {
                        Button { chapterEditorStore.cancelStream() } label: {
                            Text("取消写作")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LWColor.danger)
                                .frame(height: 46).padding(.horizontal, 18)
                                .background(LWColor.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.danger.opacity(0.3), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { startWriting() } label: {
                        Text(hasDraft(chapter) ? "重新生成" : "写作")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(LWColor.accentGradient.opacity(writeEnabled(sp) ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: LWColor.accentStop.opacity(writeEnabled(sp) ? 0.5 : 0), radius: 10, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!writeEnabled(sp) || chapterEditorStore.isStreaming)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - ③ 正文

    private func stage3(_ chapter: Chapter) -> some View {
        stageCard(panelOpacity: 0.72) {
            HStack(spacing: 9) {
                stageBadge("3")
                Text("正文").font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
                Spacer()
                // v1.2.0 (HH) P7: "模型思考中…" indicator only (mirrors
                // MacChapterEditor) — no collapsible reasoning content.
                if chapterEditorStore.isThinking {
                    thinkingIndicator
                }
                Text("\(draftWordCount(chapter)) 字").font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
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
                Text("还没有正文。回到上一步点「写作」。")
                    .font(LWFont.songti(15)).foregroundStyle(LWColor.mutedText3)
            } else {
                ForEach(Array(paragraphs(text).enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(LWFont.songti(15))
                        .foregroundStyle(LWColor.hex(0x2A2C34))
                        .lineSpacing(15)            // line-height ~2.0
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 15)
                }
                if streaming { BlinkingCaret() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryBlock(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("本章梗概 · 提取生成")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(LWColor.success)
            Text(summary)
                .font(.system(size: 13)).foregroundStyle(LWColor.hex(0x3A5C47)).lineSpacing(3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LWColor.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LWColor.success.opacity(0.18), lineWidth: 0.5))
        .padding(.top, 4)
    }

    @ViewBuilder
    private func footerButtons(_ chapter: Chapter) -> some View {
        VStack(spacing: 10) {
            if chapter.status == .draftReady && !chapterEditorStore.isStreaming {
                Button { finalize() } label: {
                    HStack(spacing: 6) {
                        if chapterEditorStore.isFinalizing { ProgressView().controlSize(.small).tint(.white) }
                        Text("完成").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(LWColor.successGradient.opacity(chapterEditorStore.isFinalizing ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: LWColor.success.opacity(0.5), radius: 10, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(chapterEditorStore.isFinalizing)
            }
            if isFinalized(chapter) {
                HStack(spacing: 10) {
                    Button { reExtract() } label: {
                        Text(chapterEditorStore.isExtracting ? "提取中…" : "提取角色/时间线")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(LWColor.secondaryText2)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(chapterEditorStore.isExtracting)

                    Button { Task { _ = await chapterEditorStore.reopen(); refreshList() } } label: {
                        Text("重新打开")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(LWColor.warning)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    /// v1.2.0 (HH) P7 — "模型思考中…" process indicator (mirrors
    /// MacChapterEditor's). Only while `chapterEditorStore.isThinking`.
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
    private func stageCard<Content: View>(panelOpacity: Double = 0.66, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(panelOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
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
            Text(label).font(.system(size: 10)).foregroundStyle(LWColor.mutedText3)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(LWColor.bodyText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(LWColor.hex(0x787D96, opacity: 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func tagGroup(label: String, color: Color, items: [String], tagFg: Color, tagBg: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            if items.isEmpty {
                Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        LWTagChip(text: item, foreground: tagFg, background: tagBg)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - State machine predicates (strict — mirrors MacChapterEditor)

    private func displayStatus(_ chapter: Chapter) -> ChapterStatus {
        chapterEditorStore.isStreaming ? .writing : chapter.status
    }
    private func isFinalized(_ chapter: Chapter) -> Bool { chapter.status == .finalized }
    private func hasDraft(_ chapter: Chapter) -> Bool { !(chapter.draftText ?? "").isEmpty }
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
    /// 展开提纲 / 重新展开 — visible in draft / prompt_ready.
    private func showExpandButton(_ chapter: Chapter) -> Bool {
        switch chapter.status {
        case .draft, .promptReady: return true
        case .writing, .draftReady, .finalized: return false
        }
    }
    /// 写作 / 重新生成 — visible in prompt_ready / draft_ready / writing.
    private func showWriteButton(_ chapter: Chapter) -> Bool {
        if chapterEditorStore.isStreaming { return true }
        switch chapter.status {
        case .promptReady, .draftReady, .writing: return true
        case .draft, .finalized: return false
        }
    }
    /// 导入文本 allowed in draft / prompt_ready / draft_ready (not writing/finalized).
    private func canImport(_ chapter: Chapter) -> Bool {
        switch chapter.status {
        case .draft, .promptReady, .draftReady: return true
        case .writing, .finalized: return false
        }
    }
    private var expandEnabled: Bool {
        !chapterEditorStore.isExpanding && !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func writeEnabled(_ sp: StructuredPrompt) -> Bool {
        !(sp.chapterGoal.isEmpty && directiveDraft.isEmpty)
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
    private var streamCharCount: Int {
        if case .streaming(_, let chars) = chapterEditorStore.writingState { return chars }
        return 0
    }

    // MARK: - Actions

    private func syncDrafts(_ chapter: Chapter?) {
        promptDraft = chapter?.userPrompt ?? ""
        directiveDraft = chapter?.structuredPrompt?.chapterDirective ?? ""
    }

    private func commitPrompt() {
        guard let chapter, promptDraft != (chapter.userPrompt ?? "") else { return }
        Task { await chapterEditorStore.patchUserPrompt(promptDraft); refreshList() }
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
                await charactersStore.load(bookId: result.chapter.bookId)
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
                    await charactersStore.load(bookId: result.chapter.bookId)
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

    private func updateTimelineSelection() {
        let involved = chapterEditorStore.chapter?.structuredPrompt?.charactersInvolved ?? []
        let preferred = involved.first(where: { id in charactersStore.characters.contains(where: { $0.id == id }) })
            ?? charactersStore.selectedCharacterId
            ?? charactersStore.characters.first?.id
        if let firstId = preferred, timelineStore.characterId != firstId {
            timelineStore.setCharacter(firstId)
            Task { await timelineStore.loadInitial() }
        }
    }
}

// MARK: - Helpers

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}
#endif
