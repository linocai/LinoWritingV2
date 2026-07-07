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
    @FocusState private var titleFocused: Bool
    @State private var titleHovered = false

    // v1.3.1 (KK) P6 — Step2 structured-prompt fields, all editable. Each
    // commits the *whole* `StructuredPrompt` object via
    // `patchStructuredPrompt` (整对象 PATCH, already how `commitDirective`
    // works) — text fields commit on blur with the same empty-guard
    // shape as the title fix (P1); Picker / tag-add / multi-select commit
    // immediately on change (no separate "save" step needed for those).
    @State private var chapterGoalDraft = ""
    @State private var sceneSettingDraft = ""
    @State private var targetWordCountDraft = ""
    @State private var extraNotesDraft = ""
    @FocusState private var chapterGoalFocused: Bool
    @FocusState private var sceneSettingFocused: Bool
    @FocusState private var targetWordCountFocused: Bool
    @FocusState private var extraNotesFocused: Bool

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
        .onChange(of: chapter?.structuredPrompt?.chapterDirective ?? "") { _, new in if !directiveFocused { directiveDraft = new } }
        // v1.3.1 (KK) P6 — the additional Step2-field onChange observers are
        // split into a second modifier chain (`stage2FieldSyncModifiers`)
        // rather than appended directly here: chaining ~10 `.onChange`/
        // `.sheet`/`.alert` calls on one `body` blew the type-checker's
        // reasonable-time budget ("unable to type-check this expression in
        // reasonable time" — a known SwiftUI complexity cliff, not a logic
        // bug). Splitting into two `.modifier` groups keeps each inference
        // problem small enough to solve quickly.
        .modifier(Stage2FieldSyncModifiers(
            chapterGoal: chapter?.structuredPrompt?.chapterGoal ?? "",
            sceneSetting: chapter?.structuredPrompt?.sceneSetting ?? "",
            targetWordCount: chapter?.structuredPrompt?.targetWordCount,
            extraNotes: chapter?.structuredPrompt?.extraNotes ?? "",
            chapterGoalFocused: chapterGoalFocused,
            sceneSettingFocused: sceneSettingFocused,
            targetWordCountFocused: targetWordCountFocused,
            extraNotesFocused: extraNotesFocused,
            chapterGoalDraft: $chapterGoalDraft,
            sceneSettingDraft: $sceneSettingDraft,
            targetWordCountDraft: $targetWordCountDraft,
            extraNotesDraft: $extraNotesDraft
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
                    StatusBadge(displayStatus(chapter))
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
                            title: chapter.status == .promptReady ? "重新起草指令" : "优化师 · 生成本章指令",
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
                        Text("改了上面的剧情？点这里让优化师重新起草第 ② 步的创作指令。")
                            .font(.system(size: 11))
                            .foregroundStyle(LWColor.mutedText3)
                    }
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

            // v1.3.1 (KK) P6 — 本章目标 (chapter_goal), now editable.
            // Required by the backend — empty-blur reverts, no PATCH.
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("本章目标")
                TextField("这一章要达成什么？", text: $chapterGoalDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(LWColor.secondaryText)
                    .lineSpacing(3)
                    .focused($chapterGoalFocused)
                    .onChange(of: chapterGoalFocused) { _, f in if !f { commitChapterGoal() } }
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

            // v1.3.1 (KK) P6 — extra_notes, now editable (multi-line).
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("补充说明")
                TextField("其它给 Writer 的补充说明…", text: $extraNotesDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.secondaryText)
                    .lineSpacing(3)
                    .focused($extraNotesFocused)
                    .onChange(of: extraNotesFocused) { _, f in if !f { commitExtraNotes() } }
            }

            // must / must-not / chars / focus — all editable now (add/remove).
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("✓ 必须发生", color: LWColor.success)
                    EditableTagList(
                        items: sp.mustHappen,
                        tagFg: LWColor.hex(0x2F7A52), tagBg: LWColor.success.opacity(0.1),
                        addPlaceholder: "必须发生的事…",
                        onAdd: addMustHappen, onRemove: removeMustHappen
                    )
                }
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("✕ 不可发生", color: LWColor.danger)
                    EditableTagList(
                        items: sp.mustNotHappen,
                        tagFg: LWColor.hex(0xB0524B), tagBg: LWColor.danger.opacity(0.1),
                        addPlaceholder: "不可发生的事…",
                        onAdd: addMustNotHappen, onRemove: removeMustNotHappen
                    )
                }
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("涉及角色", color: LWColor.mutedText3)
                    characterMultiSelect(sp)
                }
                VStack(alignment: .leading, spacing: 7) {
                    LWSectionLabel("聚焦特质 · 最多 2 个", color: LWColor.mutedText3)
                    EditableTagList(
                        items: sp.focusTraits,
                        tagFg: LWColor.authorNote, tagBg: LWColor.hex(0x9A6BE0, opacity: 0.12),
                        maxCount: 2,
                        addPlaceholder: "特质…",
                        onAdd: addFocusTrait, onRemove: removeFocusTrait
                    )
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

    // MARK: - Actions

    private func syncDrafts(_ chapter: Chapter?) {
        promptDraft = chapter?.userPrompt ?? ""
        directiveDraft = chapter?.structuredPrompt?.chapterDirective ?? ""
        titleDraft = chapter?.title ?? ""
        chapterGoalDraft = chapter?.structuredPrompt?.chapterGoal ?? ""
        sceneSettingDraft = chapter?.structuredPrompt?.sceneSetting ?? ""
        targetWordCountDraft = chapter?.structuredPrompt?.targetWordCount.map(String.init) ?? ""
        extraNotesDraft = chapter?.structuredPrompt?.extraNotes ?? ""
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
    private func commitDirective() {
        guard let chapter else { return }
        let current = chapter.structuredPrompt?.chapterDirective ?? ""
        guard directiveDraft != current else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.chapterDirective = directiveDraft.isEmpty ? nil : directiveDraft
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    // MARK: - v1.3.1 (KK) P6 — Step2 full-field edit commits

    /// `chapter_goal` is required by the backend (`require_chapter_goal`
    /// 422) — front-end guards it the same way title (P1) does: clearing the
    /// field cancels the edit (revert, no PATCH) rather than sending an
    /// empty string and eating a 422 Toast whose message is an untranslated
    /// backend string.
    private func commitChapterGoal() {
        guard let chapter else { return }
        let trimmed = chapterGoalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.chapterGoal ?? ""
        guard trimmed != original else { return }
        guard !trimmed.isEmpty else {
            chapterGoalDraft = original
            return
        }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.chapterGoal = trimmed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    /// `scene_setting` is optional — unlike `chapter_goal`, an empty value is
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

    /// `extra_notes` — optional free text, empty is legal (clears it).
    private func commitExtraNotes() {
        guard let chapter else { return }
        let trimmed = extraNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.extraNotes ?? ""
        guard trimmed != original else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.extraNotes = trimmed.isEmpty ? nil : trimmed
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

    /// `must_happen` add — tag lists commit immediately per add/remove
    /// (mirrors `MacAddFieldRow`'s immediate-commit shape, no separate blur
    /// step since there's nothing to "leave unsaved").
    private func addMustHappen(_ text: String) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.mustHappen.append(text)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    private func removeMustHappen(at index: Int) {
        guard let chapter, chapter.structuredPrompt?.mustHappen.indices.contains(index) == true else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.mustHappen.remove(at: index)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    private func addMustNotHappen(_ text: String) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.mustNotHappen.append(text)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    private func removeMustNotHappen(at index: Int) {
        guard let chapter, chapter.structuredPrompt?.mustNotHappen.indices.contains(index) == true else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.mustNotHappen.remove(at: index)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    /// `focus_traits` — front-end hard cap at 2 (plan §4 P6); `EditableTagList`'s
    /// `maxCount` hides the add control once at cap, so this only ever gets
    /// called with room to spare, but guard again defensively.
    private func addFocusTrait(_ text: String) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        guard sp.focusTraits.count < 2 else { return }
        sp.focusTraits.append(text)
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }
    private func removeFocusTrait(at index: Int) {
        guard let chapter, chapter.structuredPrompt?.focusTraits.indices.contains(index) == true else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.focusTraits.remove(at: index)
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

/// v1.3.1 (KK) P6 — carries the Step2 field `.onChange` observers that would
/// otherwise blow up `MacChapterEditor.body`'s type-checker if chained
/// inline (see the call site's doc comment). Each field mirrors the same
/// "only overwrite the draft if the user isn't actively editing it" guard
/// used throughout this file (`promptFocused`/`directiveFocused` etc.).
private struct Stage2FieldSyncModifiers: ViewModifier {
    let chapterGoal: String
    let sceneSetting: String
    let targetWordCount: Int?
    let extraNotes: String
    let chapterGoalFocused: Bool
    let sceneSettingFocused: Bool
    let targetWordCountFocused: Bool
    let extraNotesFocused: Bool
    @Binding var chapterGoalDraft: String
    @Binding var sceneSettingDraft: String
    @Binding var targetWordCountDraft: String
    @Binding var extraNotesDraft: String

    func body(content: Content) -> some View {
        content
            .onChange(of: chapterGoal) { _, new in if !chapterGoalFocused { chapterGoalDraft = new } }
            .onChange(of: sceneSetting) { _, new in if !sceneSettingFocused { sceneSettingDraft = new } }
            .onChange(of: targetWordCount) { _, new in if !targetWordCountFocused { targetWordCountDraft = new.map(String.init) ?? "" } }
            .onChange(of: extraNotes) { _, new in if !extraNotesFocused { extraNotesDraft = new } }
    }
}
#endif
