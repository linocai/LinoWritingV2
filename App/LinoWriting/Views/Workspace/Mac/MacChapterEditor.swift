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
///   ② 结构要点 (v1.5.0 NN P2 — 优化师终极精简为「框架员+选角员+领读员」,
///      四字段删除) — scene·pov·words / 涉及角色 / 情节锚点 (plot_anchors,
///      领读注解) tags / 本章文风 (chapter_style, ≤50 字), all editable
///      (v1.3.1 P6 / v1.5.0 P2); above them, an ephemeral "优化师提醒" box
///      surfaces `structured_prompt.continuity_alerts` (read-only,醒目但
///      明确是提醒非任务). "Writer · 写正文" (SSE `write`; red "■ 停止生成"
///      while streaming) is enabled purely by `user_prompt` non-empty.
///   ③ 正文 — Songti paragraphs + word count; blinking caret while streaming.
///      Status-driven footer: draft_ready → finalize; finalized → 阅读模式 /
///      重新提取 / 重新打开编辑, plus the green 本章梗概 block above.
///
/// SSE write reuses `ChapterEditorStore.startWriting` / `stopWriting`. Status
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
    @State private var titleDraft = ""
    @FocusState private var promptFocused: Bool
    @FocusState private var titleFocused: Bool
    @State private var titleHovered = false

    // v1.3.1 (KK) P6 — Step2 structured-prompt fields, all editable. Each
    // commits the *whole* `StructuredPrompt` object via
    // `patchStructuredPrompt` (整对象 PATCH) — text fields commit on blur
    // with the same empty-guard shape as the title fix (P1); Picker /
    // tag-add / multi-select commit immediately on change (no separate
    // "save" step needed for those).
    @State private var sceneSettingDraft = ""
    @State private var targetWordCountDraft = ""
    // v1.5.0 (NN) P2 — 新增：本章文风（≤50 字，优化师生成，作者可编辑/清空）。
    @State private var chapterStyleDraft = ""
    @FocusState private var sceneSettingFocused: Bool
    @FocusState private var targetWordCountFocused: Bool
    @FocusState private var chapterStyleFocused: Bool

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
        // v1.3.1 (KK) 审后修复 🟡#5: without this, renaming the currently-open
        // chapter from the sidebar's right-click "重命名" (P1) left this
        // toolbar's `titleDraft` stale — `chapter.title` updated but nothing
        // re-synced the draft (only `onAppear`/chapter-switch did). Worse,
        // if the author then focused/blurred the title field afterward,
        // `commitTitle`'s "trimmed != chapter.title" guard would see the
        // *new* server title differ from the *stale* draft and silently
        // PATCH the old title back over the rename. iOS already had this
        // exact sync (`onChange(of: chapter?.title ?? "")`); mirrored here.
        .onChange(of: chapter?.title ?? "") { _, new in if !titleFocused { titleDraft = new } }
        .onChange(of: chapter?.userPrompt ?? "") { _, new in if !promptFocused { promptDraft = new } }
        // v1.3.2 (LL) P2 — reattach to a still-running write when the window
        // becomes active again (parity with iOS scenePhase recovery). Wrapped
        // in its own ViewModifier so the scenePhase `onChange` inference stays
        // off this already-at-the-cliff body expression (see the P6 note below).
        .modifier(ReattachOnScenePhaseActive { chapterEditorStore.handleScenePhaseActive() })
        // v1.3.1 (KK) P6 — the additional Step2-field onChange observers are
        // split into a second modifier chain (`stage2FieldSyncModifiers`)
        // rather than appended directly here: chaining ~10 `.onChange`/
        // `.sheet`/`.alert` calls on one `body` blew the type-checker's
        // reasonable-time budget ("unable to type-check this expression in
        // reasonable time" — a known SwiftUI complexity cliff, not a logic
        // bug). Splitting into two `.modifier` groups keeps each inference
        // problem small enough to solve quickly.
        .modifier(Stage2FieldSyncModifiers(
            sceneSetting: chapter?.structuredPrompt?.sceneSetting ?? "",
            targetWordCount: chapter?.structuredPrompt?.targetWordCount,
            chapterStyle: chapter?.structuredPrompt?.chapterStyle ?? "",
            sceneSettingFocused: sceneSettingFocused,
            targetWordCountFocused: targetWordCountFocused,
            chapterStyleFocused: chapterStyleFocused,
            sceneSettingDraft: $sceneSettingDraft,
            targetWordCountDraft: $targetWordCountDraft,
            chapterStyleDraft: $chapterStyleDraft
        ))
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
                    StatusBadge(displayStatus(chapter), overrideLabel: displayStatusOverrideLabel())
                }
                TextField("未命名章节", text: $titleDraft, onCommit: commitTitle)
                    .textFieldStyle(.plain)
                    .font(LWFont.songti(18, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                    .frame(maxWidth: 360, alignment: .leading)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(titleHovered || titleFocused ? LWColor.accentStart.opacity(0.08) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(titleHovered || titleFocused ? LWColor.accentStart.opacity(0.28) : Color.clear, lineWidth: 0.5)
                    )
                    .overlay(alignment: .trailing) {
                        if titleHovered && !titleFocused {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LWColor.accentText)
                                .padding(.trailing, -16)
                        }
                    }
                    .onHover { hovering in
                        titleHovered = hovering
                        pointer(hovering)
                    }
                    .help("点击重命名章节标题")
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        LWAccentTintButton(
                            title: chapter.status == .promptReady ? "重新解析结构" : "优化师 · 生成本章指令",
                            systemImage: "sparkles",
                            enabled: !chapterEditorStore.isExpanding && !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) { runExpand(force: chapter.status == .promptReady) }
                        // v1.3.1 (KK) P6 — discoverability boost for the
                        // re-draft path: an accent ring around the primary
                        // action when there's already a directive to redo,
                        // so the author notices this isn't just the
                        // first-time "generate" button.
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(LWColor.accentStart.opacity(chapter.status == .promptReady ? 0.4 : 0), lineWidth: 1.2)
                        )
                        if chapterEditorStore.isExpanding {
                            ProgressView().controlSize(.small).padding(.leading, 4)
                        }
                        Spacer()
                    }
                    if chapter.status == .promptReady {
                        Text("改了上面的剧情？点这里让优化师重新解析第 ② 步的结构要点。")
                            .font(.system(size: 11))
                            .foregroundStyle(LWColor.mutedText3)
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    // MARK: ② 结构要点（v1.4.0 MM P3 — directive HERO box 已删）

    private func stage2(_ chapter: Chapter) -> some View {
        let sp = chapter.structuredPrompt ?? StructuredPrompt()
        return stageCard {
            HStack(spacing: 9) {
                stageBadge("2")
                Text("结构要点")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LWColor.bodyText)
                Spacer()
                Text("优化师整理 · 供 Writer 参考")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LWColor.accentText)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(LWColor.accentStart.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("这是优化师从你写的本章剧情里收束出的结构要点，全部可编辑；写作时以你的本章剧情原文为最高权威。")
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // v1.4.0 (MM) P1/P3 — 优化师「连续性/矛盾校对」提醒：醒目但明确是
            // 提醒非任务，只读，绝不进 Writer 输入。空数组时整块不渲染。
            if !sp.continuityAlerts.isEmpty {
                continuityAlertsBox(sp.continuityAlerts)
            }

            // scene / pov / target word count — all editable now.
            HStack(alignment: .top, spacing: 10) {
                editableInfoCell(label: "场景") {
                    TextField("—", text: $sceneSettingDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LWColor.bodyText)
                        .focused($sceneSettingFocused)
                        .onChange(of: sceneSettingFocused) { _, f in if !f { commitSceneSetting() } }
                }
                editableInfoCell(label: "视角") {
                    Picker("", selection: povBinding) {
                        Text("未定").tag(NarrativePOV?.none)
                        ForEach(NarrativePOV.allCases, id: \.self) { pov in
                            Text(pov.label).tag(NarrativePOV?.some(pov))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 13, weight: .medium))
                }
                editableInfoCell(label: "目标字数") {
                    HStack(spacing: 2) {
                        TextField("不限", text: $targetWordCountDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LWColor.bodyText)
                            .focused($targetWordCountFocused)
                            .onChange(of: targetWordCountFocused) { _, f in if !f { commitTargetWordCount() } }
                        if !targetWordCountDraft.isEmpty { Text("字").font(.system(size: 11)).foregroundStyle(LWColor.mutedText3) }
                    }
                }
            }

            // v1.5.0 (NN) P2 — 新增：本章文风 (chapter_style)，优化师生成的
            // ≤50 字文风提示（句式/节奏/用词密度/叙事温度），作者可编辑/清空；
            // 替代已退场的全局「文风指令」。
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("本章文风")
                TextField("句式/节奏/用词密度/叙事温度，≤50 字，可留空", text: $chapterStyleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.secondaryText)
                    .lineSpacing(3)
                    .focused($chapterStyleFocused)
                    .onChange(of: chapterStyleFocused) { _, f in if !f { commitChapterStyle() } }
                Text("留空则遵循 Writer 人格里的整体文风底色。")
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.mutedText3)
            }

            // plot anchors / chars — all editable now (add/remove).
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("情节锚点", color: LWColor.success)
                    EditableTagList(
                        items: sp.plotAnchors,
                        tagFg: LWColor.hex(0x2F7A52), tagBg: LWColor.success.opacity(0.1),
                        addPlaceholder: "帮 Writer 领读的情节锚点…",
                        onAdd: addPlotAnchor, onRemove: removePlotAnchor
                    )
                }
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("涉及角色", color: LWColor.mutedText3)
                    characterMultiSelect(sp)
                }
            }

            if showWriteButton(chapter) {
                HStack(spacing: 10) {
                    if chapterEditorStore.isStreaming || chapterEditorStore.isRevising {
                        // v1.4.0 (MM) P4 — same button/action during revising:
                        // "停止生成" cancels the compression and keeps the
                        // complete draft (backend cancel×revising matrix),
                        // wording unchanged per plan.
                        LWDangerTintButton(title: "停止生成", systemImage: "stop.fill") {
                            chapterEditorStore.stopWriting()
                        }
                    } else {
                        LWPrimaryButton(
                            title: hasDraft(chapter) ? "Writer · 重新生成" : "Writer · 写正文",
                            systemImage: "pencil",
                            enabled: !(chapter.userPrompt ?? "").isEmpty
                        ) { startWriting() }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    /// v1.4.0 (MM) P3 — 优化师提醒（`continuity_alerts`）：醒目的警示配色，
    /// 但文案明确标注「提醒」而非任务，只读、不可编辑。
    private func continuityAlertsBox(_ alerts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LWColor.warning)
                Text("优化师提醒 · 连续性/矛盾核对，仅供参考")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LWColor.warning)
            }
            ForEach(alerts, id: \.self) { alert in
                Text("· \(alert)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.bodyText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LWColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LWColor.warning.opacity(0.28), lineWidth: 1)
        )
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
                // v1.4.0 (MM) P4 — mirrors thinkingIndicator's shape for the
                // (up to 5 分钟) two-pass compression call; mutually
                // exclusive with isThinking (thinking never coincides with
                // revising).
                if chapterEditorStore.isRevising {
                    revisingIndicator
                }
                Text("\(draftWordCount(chapter)) 字")
                    .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
            }

            draftBody(chapter)

            if isFinalized(chapter), let summary = chapter.summary, !summary.isEmpty {
                summaryBlock(summary)
            }

            // v1.4.0 (MM) P4 — ephemeral "未修订" marker (this session only,
            // vanishes on reload/chapter switch); the 修订 button below is
            // always available in draft_ready to retry manually.
            if chapterEditorStore.lastRevisionOutcome == "unrevised" {
                unrevisedBadge
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
            if chapter.status == .draftReady && !chapterEditorStore.isStreaming && !chapterEditorStore.isRevising {
                LWSuccessButton(title: "档案员 · 提取入库", systemImage: "checkmark", enabled: !chapterEditorStore.isFinalizing) {
                    finalize()
                }
            }
            // v1.4.0 (MM) P4 — 修订按钮：draft_ready 态可见（含「未修订」兜底
            // 重试入口），running 时置灰（不隐藏，`chapter.status` 在流式/修订
            // 期本就滞后停在 draft_ready，"置灰" 是唯一能表达"忙"的方式）。
            if chapter.status == .draftReady {
                LWBorderedButton(
                    title: "修订 · 压缩字数",
                    systemImage: "wand.and.stars",
                    enabled: !chapterEditorStore.isStreaming && !chapterEditorStore.isRevising && !chapterEditorStore.isFinalizing
                ) {
                    startRevise()
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

    /// v1.4.0 (MM) P4 — "修订中…" process indicator (stage3 header, only
    /// while `chapterEditorStore.isRevising`). The compression call is a
    /// single blocking round-trip (up to 300s × up to 2 attempts) — this is
    /// the only in-flight feedback during that window besides the toolbar
    /// badge, which may be scrolled off-screen while reading stage3.
    private var revisingIndicator: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text("修订中…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LWColor.mutedText3)
        }
    }

    /// v1.4.0 (MM) P4 — ephemeral "未修订" tag: the compression call itself
    /// failed, so the (possibly still over-length) initial draft was kept
    /// as-is. Paired with the errorBus Toast fired once from
    /// `ChapterEditorStore.applyWriteEvent`; this tag is the persistent (for
    /// the rest of THIS session) in-UI reminder that the 修订 button below
    /// is the manual retry.
    private var unrevisedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LWColor.warning)
            Text("未修订 · 字数可能超标，可点下方「修订」重试")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LWColor.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// v1.3.1 (KK) P6 — editable variant of `infoCell`: same visual chrome,
    /// but hosts an inline control (`TextField`/`Picker`) instead of a
    /// read-only `Text`.
    private func editableInfoCell<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(LWColor.mutedText3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LWColor.hex(0x787D96, opacity: 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Binding shim so `Picker` can drive `commitNarrativePov` directly —
    /// the picker has no separate "commit" step, selection IS the commit.
    private var povBinding: Binding<NarrativePOV?> {
        Binding(
            get: { chapter?.structuredPrompt?.narrativePov },
            set: { commitNarrativePov($0) }
        )
    }

    /// v1.3.1 (KK) P6 — `characters_involved` multi-select against the
    /// book's existing roster (`charactersStore.characters`). Each chip
    /// toggles membership on tap; selected chips get the accent tint so the
    /// author can see at a glance which characters this chapter is flagged
    /// for, mirroring `MacCharacterTab.chip`'s selected/unselected treatment.
    @ViewBuilder
    private func characterMultiSelect(_ sp: StructuredPrompt) -> some View {
        if charactersStore.characters.isEmpty {
            Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
        } else {
            FlowLayout(spacing: 7) {
                ForEach(charactersStore.characters) { ch in
                    let selected = sp.charactersInvolved.contains(ch.id)
                    Button { toggleCharacterInvolved(ch.id) } label: {
                        Text(ch.name)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? LWColor.secondaryText2 : LWColor.mutedText3)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(
                                selected ? LWColor.hex(0x787D96, opacity: 0.16) : LWColor.hex(0x787D96, opacity: 0.05),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selected ? LWColor.hex(0x787D96, opacity: 0.35) : Color.clear, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - State machine predicates (strict)

    private func displayStatus(_ chapter: Chapter) -> ChapterStatus {
        (chapterEditorStore.isStreaming || chapterEditorStore.isRevising) ? .writing : chapter.status
    }
    /// v1.4.0 (MM) P4 — the badge's two-stage label ("写作中"→"修订中"); both
    /// map to the same `.writing` `ChapterStatus`/color (there is no separate
    /// persisted status for revising), so the distinction is purely this
    /// label override.
    private func displayStatusOverrideLabel() -> String? {
        chapterEditorStore.isRevising ? "修订中" : nil
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
        if chapterEditorStore.isStreaming || chapterEditorStore.isRevising { return true }
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
        // v1.4.0 (MM) P4 — revising carries its own buffer forward (🔵9): the
        // draft never disappears while the compression call is in flight.
        if case .revising(let buffer, _) = chapterEditorStore.writingState, !buffer.isEmpty {
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

    // MARK: - Actions

    private func syncDrafts(_ chapter: Chapter?) {
        promptDraft = chapter?.userPrompt ?? ""
        titleDraft = chapter?.title ?? ""
        sceneSettingDraft = chapter?.structuredPrompt?.sceneSetting ?? ""
        targetWordCountDraft = chapter?.structuredPrompt?.targetWordCount.map(String.init) ?? ""
        chapterStyleDraft = chapter?.structuredPrompt?.chapterStyle ?? ""
    }

    private func commitPrompt() {
        guard let chapter, promptDraft != (chapter.userPrompt ?? "") else { return }
        Task { await chapterEditorStore.patchUserPrompt(promptDraft); refreshList() }
    }
    /// v1.3.1 (KK) P1 — failed-to-commit-on-blur fix: the title `TextField`
    /// used to only submit via `onCommit` (⏎); clicking elsewhere lost the
    /// edit silently. Now driven by `titleFocused` (fires on blur too), with
    /// an empty-title guard: clearing the field is treated as a cancelled
    /// edit — `titleDraft` reverts to the original value via `syncDrafts`'s
    /// `onChange(of: chapter?.id)`/`onAppear`, and no PATCH is sent.
    private func commitTitle() {
        guard let chapter else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        let original = chapter.title ?? ""
        guard trimmed != original else { return }
        guard !trimmed.isEmpty else {
            // Empty title = cancel, not "clear the title". Revert the draft
            // so the toolbar doesn't keep showing a blank field.
            titleDraft = original
            return
        }
        Task { await chapterEditorStore.patchTitle(trimmed); refreshList() }
    }
    // MARK: - v1.3.1 (KK) P6 — Step2 full-field edit commits

    /// `scene_setting` is optional — an empty value is
    /// legal (clears the field), so no revert-on-blank guard here.
    private func commitSceneSetting() {
        guard let chapter else { return }
        let trimmed = sceneSettingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.sceneSetting ?? ""
        guard trimmed != original else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.sceneSetting = trimmed.isEmpty ? nil : trimmed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    /// `target_word_count` — optional positive integer. Blank means "不限"
    /// (nil, legal). 0 / negative / non-numeric input is guarded on the
    /// front end (never sent) rather than relying on the backend's `gt=0`
    /// 422, mirroring the `chapter_goal` guard's rationale (P6 plan note).
    private func commitTargetWordCount() {
        guard let chapter else { return }
        let trimmed = targetWordCountDraft.trimmingCharacters(in: .whitespaces)
        let originalValue = chapter.structuredPrompt?.targetWordCount
        if trimmed.isEmpty {
            guard originalValue != nil else { return }
            var sp = chapter.structuredPrompt ?? StructuredPrompt()
            sp.targetWordCount = nil
            Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
            return
        }
        guard let parsed = Int(trimmed), parsed > 0 else {
            // Illegal input (0 / negative / non-numeric) — revert the draft
            // to whatever the chapter currently holds; never PATCH.
            targetWordCountDraft = originalValue.map(String.init) ?? ""
            return
        }
        guard parsed != originalValue else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.targetWordCount = parsed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    /// v1.5.0 (NN) P2 — `chapter_style` optional free text (≤50 字 guideline,
    /// server-side truncates on `expand()`); empty is legal (clears it).
    private func commitChapterStyle() {
        guard let chapter else { return }
        let trimmed = chapterStyleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.chapterStyle ?? ""
        guard trimmed != original else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.chapterStyle = trimmed.isEmpty ? nil : trimmed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    /// `narrative_pov` — Picker commits immediately on selection change (no
    /// blur step needed for a picker).
    private func commitNarrativePov(_ pov: NarrativePOV?) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.narrativePov = pov
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    /// v1.5.0 (NN) P2 — `plot_anchors` add/remove (由 `must_happen` 改名，
    /// 定性从「验收清单」变「领读注解」). Tag lists commit immediately per
    /// add/remove (mirrors `MacAddFieldRow`'s immediate-commit shape, no
    /// separate blur step since there's nothing to "leave unsaved").
    private func addPlotAnchor(_ text: String) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.plotAnchors.append(text)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    private func removePlotAnchor(at index: Int) {
        guard let chapter, chapter.structuredPrompt?.plotAnchors.indices.contains(index) == true else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.plotAnchors.remove(at: index)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    /// `characters_involved` — multi-select toggle against the book's
    /// existing character roster.
    private func toggleCharacterInvolved(_ characterId: String) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        if let idx = sp.charactersInvolved.firstIndex(of: characterId) {
            sp.charactersInvolved.remove(at: idx)
        } else {
            sp.charactersInvolved.append(characterId)
        }
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
        chapterEditorStore.startWriting { chapter in
            chaptersStore.upsert(chapter)
        }
    }

    /// v1.4.0 (MM) P4 — manual "修订" trigger (`POST /revise`), independent
    /// of a fresh Writer regeneration.
    private func startRevise() {
        chapterEditorStore.revise { chapter in
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

/// v1.3.2 (LL) P2 — fires `onActive` whenever the app returns to the
/// foreground. Kept as its own modifier so the `scenePhase` `onChange`
/// inference doesn't add to `MacChapterEditor.body`'s already-at-the-cliff
/// type-check budget.
private struct ReattachOnScenePhaseActive: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let onActive: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active { onActive() }
        }
    }
}

/// v1.3.1 (KK) P6 — carries the Step2 field `.onChange` observers that would
/// otherwise blow up `MacChapterEditor.body`'s type-checker if chained
/// inline (see the call site's doc comment). Each field mirrors the same
/// "only overwrite the draft if the user isn't actively editing it" guard
/// used throughout this file (`promptFocused`/`titleFocused` etc.).
private struct Stage2FieldSyncModifiers: ViewModifier {
    let sceneSetting: String
    let targetWordCount: Int?
    let chapterStyle: String
    let sceneSettingFocused: Bool
    let targetWordCountFocused: Bool
    let chapterStyleFocused: Bool
    @Binding var sceneSettingDraft: String
    @Binding var targetWordCountDraft: String
    @Binding var chapterStyleDraft: String

    func body(content: Content) -> some View {
        content
            .onChange(of: sceneSetting) { _, new in if !sceneSettingFocused { sceneSettingDraft = new } }
            .onChange(of: targetWordCount) { _, new in if !targetWordCountFocused { targetWordCountDraft = new.map(String.init) ?? "" } }
            .onChange(of: chapterStyle) { _, new in if !chapterStyleFocused { chapterStyleDraft = new } }
    }
}
#endif
