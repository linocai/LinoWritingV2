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
///   - ② 结构要点 (v1.4.0 MM P3 — directive HERO box 已删，优化师降职为结构员+
///     校对员): goal/scene/pov/字数/must·must-not·chars·focus，全部可编辑；
///     上方按需展示「优化师提醒」（`continuity_alerts`，只读、醒目但非任务）;
///     写作 (prompt_ready)/重新生成 (draft_ready) → `POST .../write` (SSE);
///     取消写作 while streaming.
///   - ③ 正文: Songti paragraphs + **streaming 逐字 + 闪烁光标**; finalized 绿色
///     本章梗概 block. Footer: draft_ready→完成 `POST .../finalize`;
///     finalized→提取角色/时间线 `POST .../extract` + 重新打开 `POST .../reopen`.
///
/// SSE reuses `ChapterEditorStore.startWriting` / `stopWriting` / `writingState`
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
    @FocusState private var promptFocused: Bool

    // v1.3.1 (KK) P2 — chapter title, hand-typed only (no LLM suggestion,
    // author's call). Editing via an inline navBar `TextField` (iOS-idiomatic
    // over an `.alert`); commits on blur, mirroring macOS's `commitTitle`.
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    // v1.3.1 (KK) P6 — Step2 structured-prompt fields, all editable. Mirrors
    // MacChapterEditor's field set exactly — see its doc comment for the
    // commit-shape rationale (整对象 PATCH via `patchStructuredPrompt`).
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
    @State private var showDeleteConfirm = false
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
        .onChange(of: chapter?.title ?? "") { _, new in if !titleFocused { titleDraft = new } }
        // v1.3.2 (LL) P2 — returning to the foreground reattaches to a write
        // that kept running while the phone slept (the "息屏 5 分钟回来" path).
        // Wrapped in its own modifier to keep scenePhase inference off this body.
        .modifier(ReattachOnScenePhaseActiveIOS { chapterEditorStore.handleScenePhaseActive() })
        // v1.3.1 (KK) P6 — the Step2-field onChange observers are split into
        // a second modifier chain (see `MacChapterEditor`'s identical fix
        // and its doc comment) — chaining this many `.onChange`/`.sheet`/
        // `.alert`/`.task` calls on one `body` blew the type-checker's
        // reasonable-time budget.
        .modifier(Stage2FieldSyncModifiersIOS(
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
        // v1.3.1 (KK) P2 — delete-章 confirmation, edit-page menu entry.
        // Deleting the currently-open chapter must dismiss back to the list
        // (there's nothing left to show once the row is gone).
        .alert("删除本章？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteChapter() }
        } message: {
            Text("章节及其正文、结构化提示、关联事件都会删除，且无法撤销。")
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
                    IOSStatusChip(status: displayStatus(chapter), overrideLabel: displayStatusOverrideLabel())
                }
                // v1.3.1 (KK) P2 — inline-editable title (hand-typed only,
                // no LLM suggestion). Commits on blur via `titleFocused`;
                // an empty title cancels the edit (reverts, no PATCH) —
                // same guard shape as macOS `MacChapterEditor.commitTitle`.
                TextField("未命名", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(LWFont.songti(16, weight: .bold))
                    .foregroundStyle(LWColor.titleText)
                    .lineLimit(1)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .onSubmit { commitTitle() }
                    .frame(maxWidth: 200)
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
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("删除本章", systemImage: "trash")
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
                // v1.3.1 (KK) P6 — discoverability boost for the re-draft
                // path (mirrors MacChapterEditor's ring + caption treatment):
                // a stronger accent ring + explanatory caption when there's
                // already a directive to redo, so it doesn't read as just
                // the first-time "expand" button.
                let isRedraft = chapter.structuredPrompt != nil
                VStack(alignment: .leading, spacing: 6) {
                    Button { runExpand(force: chapter.status == .promptReady) } label: {
                        HStack(spacing: 6) {
                            if chapterEditorStore.isExpanding {
                                ProgressView().controlSize(.small)
                            }
                            Text(isRedraft ? "重新解析结构" : "展开提纲")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(LWColor.accentText)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(LWColor.accentStart.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(LWColor.accentStart.opacity(isRedraft ? 0.45 : 0.25), lineWidth: isRedraft ? 1.2 : 0.5)
                        )
                        .opacity(expandEnabled ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!expandEnabled)
                    if isRedraft {
                        Text("改了上面的剧情？点这里让优化师重新解析第 ② 步的结构要点。")
                            .font(.system(size: 11))
                            .foregroundStyle(LWColor.mutedText3)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - ② 结构要点（v1.4.0 MM P3 — directive HERO box 已删）

    private func stage2(_ chapter: Chapter) -> some View {
        let sp = chapter.structuredPrompt ?? StructuredPrompt()
        return stageCard {
            HStack(spacing: 9) {
                stageBadge("2")
                Text("结构要点").font(.system(size: 14, weight: .semibold)).foregroundStyle(LWColor.bodyText)
                Spacer()
            }
            Text("优化师从你写的本章剧情里收束出的结构要点，全部可编辑；写作时以你的本章剧情原文为最高权威。")
                .font(.system(size: 11.5)).foregroundStyle(LWColor.mutedText3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // v1.4.0 (MM) P1/P3 — 优化师「连续性/矛盾校对」提醒：醒目但明确是
            // 提醒非任务，只读，绝不进 Writer 输入。空数组时整块不渲染。
            if !sp.continuityAlerts.isEmpty {
                continuityAlertsBox(sp.continuityAlerts)
            }

            // v1.3.1 (KK) P6 — 本章目标 (chapter_goal), now editable. Required
            // by the backend — empty-blur reverts, no PATCH (mirrors macOS).
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("本章目标")
                TextField("这一章要达成什么？", text: $chapterGoalDraft, axis: .vertical)
                    .font(.system(size: 13.5)).foregroundStyle(LWColor.secondaryText).lineSpacing(3)
                    .focused($chapterGoalFocused)
                    .onChange(of: chapterGoalFocused) { _, f in if !f { commitChapterGoal() } }
            }

            // 场景 / 视角 / 字数 (3-up) — all editable now.
            //
            // v1.3.1 (KK) 审后修复 🟡#1: the row lacked `alignment: .top`
            // (macOS's version has it), so once the 视角 cell got tall its
            // shorter siblings vertical-centred and visually drifted against
            // "补充说明" below. And a menu-style `Picker`'s inline selection
            // label (e.g. "第三人称（限知）", 8 CJK glyphs) doesn't honor
            // `.lineLimit`/`.fixedSize` applied to the `Picker` itself — that
            // constrains the *picker view*, not the auto-echoed selection
            // text it renders internally, so `.lineLimit(1)` alone (tried
            // first, confirmed insufficient by a scaffold screenshot) still
            // wrapped into 2 lines. This is the same "compact-width CJK label
            // wraps" failure mode as the v0.9.4 ChapterToolbar bug documented
            // in CLAUDE.md — the durable fix there was switching to
            // `.labelStyle(.iconOnly)`/short labels, not width tricks on the
            // wrapping component. Same move here: a hand-built `Menu` with a
            // short custom label (`narrativePovShortLabel`, 2-4 CJK chars)
            // that we fully control, instead of `Picker`'s auto-echo. The row
            // also gets `alignment: .top` so mismatched cell heights no
            // longer drift.
            HStack(alignment: .top, spacing: 8) {
                editableInfoCell(label: "场景") {
                    TextField("—", text: $sceneSettingDraft)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LWColor.bodyText)
                        .lineLimit(1)
                        .focused($sceneSettingFocused)
                        .onChange(of: sceneSettingFocused) { _, f in if !f { commitSceneSetting() } }
                }
                editableInfoCell(label: "视角") {
                    Menu {
                        Button("未定") { commitNarrativePov(nil) }
                        ForEach(NarrativePOV.allCases, id: \.self) { pov in
                            Button(pov.label) { commitNarrativePov(pov) }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(narrativePovShortLabel(chapter.structuredPrompt?.narrativePov))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LWColor.bodyText)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(LWColor.mutedText3)
                        }
                    }
                }
                editableInfoCell(label: "字数") {
                    HStack(spacing: 2) {
                        TextField("不限", text: $targetWordCountDraft)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(LWColor.bodyText)
                            .lineLimit(1)
                            .keyboardType(.numberPad)
                            .focused($targetWordCountFocused)
                            .onChange(of: targetWordCountFocused) { _, f in if !f { commitTargetWordCount() } }
                        if !targetWordCountDraft.isEmpty { Text("字").font(.system(size: 10)).foregroundStyle(LWColor.mutedText3) }
                    }
                }
            }

            // v1.3.1 (KK) P6 — extra_notes, now editable (multi-line).
            VStack(alignment: .leading, spacing: 5) {
                LWSectionLabel("补充说明")
                TextField("其它给 Writer 的补充说明…", text: $extraNotesDraft, axis: .vertical)
                    .font(.system(size: 13)).foregroundStyle(LWColor.secondaryText).lineSpacing(3)
                    .focused($extraNotesFocused)
                    .onChange(of: extraNotesFocused) { _, f in if !f { commitExtraNotes() } }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("必须发生").font(.system(size: 11, weight: .bold)).foregroundStyle(LWColor.success)
                    EditableTagList(
                        items: sp.mustHappen,
                        tagFg: LWColor.hex(0x2F7A52), tagBg: LWColor.success.opacity(0.1),
                        addPlaceholder: "必须发生的事…",
                        onAdd: addMustHappen, onRemove: removeMustHappen
                    )
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("禁止发生").font(.system(size: 11, weight: .bold)).foregroundStyle(LWColor.danger)
                    EditableTagList(
                        items: sp.mustNotHappen,
                        tagFg: LWColor.hex(0xB0524B), tagBg: LWColor.danger.opacity(0.1),
                        addPlaceholder: "不可发生的事…",
                        onAdd: addMustNotHappen, onRemove: removeMustNotHappen
                    )
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("出场角色").font(.system(size: 11, weight: .bold)).foregroundStyle(LWColor.mutedText3)
                    characterMultiSelect(sp)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("本章人格重点 · 最多 2 个").font(.system(size: 11, weight: .bold)).foregroundStyle(LWColor.mutedText3)
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
                    if chapterEditorStore.isStreaming || chapterEditorStore.isRevising {
                        // v1.4.0 (MM) P4 — same button/action during revising:
                        // "停止生成" cancels the compression and keeps the
                        // complete draft (backend cancel×revising matrix),
                        // wording unchanged per plan.
                        Button { chapterEditorStore.stopWriting() } label: {
                            Text("停止生成")
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
                    .disabled(!writeEnabled(sp) || chapterEditorStore.isStreaming || chapterEditorStore.isRevising)
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
                // v1.4.0 (MM) P4 — mirrors thinkingIndicator's shape for the
                // (up to 5 分钟) two-pass compression call.
                if chapterEditorStore.isRevising {
                    revisingIndicator
                }
                Text("\(draftWordCount(chapter)) 字").font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
            }

            draftBody(chapter)

            if isFinalized(chapter), let summary = chapter.summary, !summary.isEmpty {
                summaryBlock(summary)
            }

            // v1.4.0 (MM) P4 — ephemeral "未修订" marker (this session only).
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
            if chapter.status == .draftReady && !chapterEditorStore.isStreaming && !chapterEditorStore.isRevising {
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
            // v1.4.0 (MM) P4 — 修订按钮：draft_ready 态可见（含「未修订」兜底
            // 重试入口），running 时置灰（不隐藏，理由同 macOS）。
            if chapter.status == .draftReady {
                let reviseEnabled = !chapterEditorStore.isStreaming && !chapterEditorStore.isRevising && !chapterEditorStore.isFinalizing
                Button { startRevise() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .medium))
                        Text("修订 · 压缩字数").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(LWColor.secondaryText2)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
                    .opacity(reviseEnabled ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!reviseEnabled)
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

    /// v1.4.0 (MM) P4 — "修订中…" process indicator (mirrors
    /// MacChapterEditor's `revisingIndicator`). Only while
    /// `chapterEditorStore.isRevising`.
    private var revisingIndicator: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text("修订中…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LWColor.mutedText3)
        }
    }

    /// v1.4.0 (MM) P4 — ephemeral "未修订" tag (mirrors MacChapterEditor's
    /// `unrevisedBadge`).
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

    /// v1.4.0 (MM) P3 — 优化师提醒（`continuity_alerts`）：醒目的警示配色，
    /// 但文案明确标注「提醒」而非任务，只读、不可编辑（mirrors macOS）。
    private func continuityAlertsBox(_ alerts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LWColor.warning)
                Text("优化师提醒 · 连续性/矛盾核对，仅供参考")
                    .font(.system(size: 11, weight: .semibold))
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
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LWColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LWColor.warning.opacity(0.28), lineWidth: 1)
        )
    }

    /// v1.3.1 (KK) P6 — editable variant of the old read-only `infoCell`:
    /// same visual chrome, hosts an inline control instead of static `Text`.
    private func editableInfoCell<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(LWColor.mutedText3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(LWColor.hex(0x787D96, opacity: 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Binding shim so `Picker` can drive `commitNarrativePov` directly.
    /// v1.3.1 (KK) 审后修复 🟡#1 — short label for the 视角 cell's custom
    /// `Menu` button (2-4 CJK chars, vs. `NarrativePOV.label`'s full 4-8
    /// char form used everywhere else, e.g. Step2's structure-points display
    /// and the `Menu`'s own dropdown rows). Keeps the narrow 3-up cell from
    /// ever needing to wrap.
    private func narrativePovShortLabel(_ pov: NarrativePOV?) -> String {
        switch pov {
        case .none: return "未定"
        case .firstPerson: return "第一人称"
        case .thirdPersonLimited: return "限知"
        case .thirdPersonOmniscient: return "全知"
        }
    }

    /// v1.3.1 (KK) P6 — `characters_involved` multi-select against the
    /// book's roster (mirrors `MacChapterEditor.characterMultiSelect`).
    @ViewBuilder
    private func characterMultiSelect(_ sp: StructuredPrompt) -> some View {
        if charactersStore.characters.isEmpty {
            Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
        } else {
            FlowLayout(spacing: 6) {
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

    // MARK: - State machine predicates (strict — mirrors MacChapterEditor)

    private func displayStatus(_ chapter: Chapter) -> ChapterStatus {
        (chapterEditorStore.isStreaming || chapterEditorStore.isRevising) ? .writing : chapter.status
    }
    /// v1.4.0 (MM) P4 — mirrors `MacChapterEditor`'s badge label override.
    private func displayStatusOverrideLabel() -> String? {
        chapterEditorStore.isRevising ? "修订中" : nil
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
        if chapterEditorStore.isStreaming || chapterEditorStore.isRevising { return true }
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
        !sp.chapterGoal.isEmpty || !(chapter?.userPrompt ?? "").isEmpty
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
    private var streamCharCount: Int {
        if case .streaming(_, let chars) = chapterEditorStore.writingState { return chars }
        return 0
    }

    // MARK: - Actions

    private func syncDrafts(_ chapter: Chapter?) {
        promptDraft = chapter?.userPrompt ?? ""
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
    /// v1.3.1 (KK) P2 — same empty-cancels-edit guard as macOS's
    /// `MacChapterEditor.commitTitle`: clearing the field reverts the draft
    /// and skips the PATCH rather than clearing the stored title.
    private func commitTitle() {
        guard let chapter else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        let original = chapter.title ?? ""
        guard trimmed != original else { return }
        guard !trimmed.isEmpty else {
            titleDraft = original
            return
        }
        Task { await chapterEditorStore.patchTitle(trimmed); refreshList() }
    }
    /// v1.3.1 (KK) P2 — delete the currently-open chapter, then dismiss back
    /// to the chapters list (nothing left in this destination to show).
    /// v1.3.1 (KK) 审后修复 建议#7: `ChaptersStore.delete` doesn't return a
    /// success flag (it publishes to ErrorBus internally on failure) — the
    /// old code called `dismiss()` unconditionally, so a network error left
    /// the ErrorBus Toast saying "failed" while the app still navigated back
    /// as if it had succeeded (章 still exists, but the user's already been
    /// bounced to the list). Check whether the row actually left
    /// `chaptersStore.chapters` before deciding to dismiss.
    private func deleteChapter() {
        guard let chapter else { return }
        Task {
            await chaptersStore.delete(id: chapter.id)
            let stillExists = chaptersStore.chapters.contains { $0.id == chapter.id }
            if !stillExists {
                dismiss()
            }
            // On failure the row is still present and ErrorBus already
            // published a Toast — stay on this page so the user can retry.
        }
    }
    // MARK: - v1.3.1 (KK) P6 — Step2 full-field edit commits (mirrors
    // MacChapterEditor's commit* functions exactly).

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

    private func commitSceneSetting() {
        guard let chapter else { return }
        let trimmed = sceneSettingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.sceneSetting ?? ""
        guard trimmed != original else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.sceneSetting = trimmed.isEmpty ? nil : trimmed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

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
            targetWordCountDraft = originalValue.map(String.init) ?? ""
            return
        }
        guard parsed != originalValue else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.targetWordCount = parsed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    private func commitExtraNotes() {
        guard let chapter else { return }
        let trimmed = extraNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chapter.structuredPrompt?.extraNotes ?? ""
        guard trimmed != original else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.extraNotes = trimmed.isEmpty ? nil : trimmed
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

    private func commitNarrativePov(_ pov: NarrativePOV?) {
        guard let chapter else { return }
        var sp = chapter.structuredPrompt ?? StructuredPrompt()
        sp.narrativePov = pov
        Task { await chapterEditorStore.patchStructuredPrompt(sp); refreshList() }
    }

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
        if chapterGoalFocused { commitChapterGoal() }
        chapterEditorStore.startWriting { chapter in
            chaptersStore.upsert(chapter)
        }
    }

    /// v1.4.0 (MM) P4 — manual "修订" trigger (`POST /revise`), independent
    /// of a fresh Writer regeneration (mirrors `MacChapterEditor.startRevise`).
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

/// v1.3.2 (LL) P2 — iOS twin of `ReattachOnScenePhaseActive`: fires `onActive`
/// on foreground return (the 息屏回来 reattach path), kept off the body's
/// type-check budget.
private struct ReattachOnScenePhaseActiveIOS: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let onActive: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active { onActive() }
        }
    }
}

/// v1.3.1 (KK) P6 — iOS twin of `MacChapterEditor`'s `Stage2FieldSyncModifiers`
/// (same rationale: keeps `IOSChapterEditPlaceholder.body`'s modifier chain
/// short enough for the type-checker).
private struct Stage2FieldSyncModifiersIOS: ViewModifier {
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
