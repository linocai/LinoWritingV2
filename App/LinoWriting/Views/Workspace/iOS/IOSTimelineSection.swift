#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 时间线 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 时间线 tab:
///   - "{角色名} 的时间线 · 由档案员写入（先在「角色」选人）" hint.
///   - selected character's events on a vertical axis: each = event_type label
///     + 第 N 章 + 已编辑 marker (`edited_at` non-null) + delete
///     (`DELETE /timeline_events/{id}`); text inline edit
///     (`PATCH /timeline_events/{id}`).
///   - **NO add button** — only the Extractor (档案员) writes events.
///
/// Follows the currently-selected character in `CharactersStore`; when that
/// changes (e.g. the user picks another character in the 角色 segment) the
/// timeline reloads. Mirrors `MacTimelineTab` reflowed for iPhone. iOS-only.
struct IOSTimelineSection: View {
    @EnvironmentObject var timelineStore: TimelineStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var pendingDelete: TimelineEvent?

    private var ownerName: String {
        guard let id = timelineStore.characterId
            ?? charactersStore.selectedCharacterId else { return "未选择角色" }
        return charactersStore.characters.first(where: { $0.id == id })?.name ?? "角色"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(ownerName) 的时间线 · 由档案员写入（先在「角色」选人）")
                .font(.system(size: 13))
                .foregroundStyle(LWColor.mutedText3)
                .padding(.bottom, 16)

            if timelineStore.events.isEmpty {
                emptyState
            } else {
                ForEach(Array(timelineStore.events.enumerated()), id: \.element.id) { idx, event in
                    eventRow(event, isLast: idx == timelineStore.events.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await syncTimelineToSelectedCharacter() }
        .onChange(of: charactersStore.selectedCharacterId) { _, _ in
            Task { await syncTimelineToSelectedCharacter() }
        }
        .alert("删除这条事件？",
               isPresented: .constant(pendingDelete != nil),
               presenting: pendingDelete) { e in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = e
                pendingDelete = nil
                Task { await timelineStore.deleteEvent(id: target.id) }
            }
        } message: { _ in Text("时间线事件删除后不可恢复。") }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("暂无时间线事件")
                .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
            Text("完成章节提取后会自动出现")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func eventRow(_ event: TimelineEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(LWColor.accentStart).frame(width: 10, height: 10).padding(.top, 5)
                if !isLast {
                    Rectangle().fill(LWColor.accentStart.opacity(0.2)).frame(width: 1.5)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(event.eventType.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LWColor.accentText)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(LWColor.accentStart.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("第 \(event.chapterIndex) 章")
                        .font(.system(size: 11.5)).foregroundStyle(LWColor.mutedText3)
                    if event.editedAt != nil {
                        Text("已编辑").font(.system(size: 10.5)).foregroundStyle(LWColor.warning)
                    }
                    Spacer()
                    Button { pendingDelete = event } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(LWColor.danger)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                IOSTimelineText(event: event) { newText in
                    Task { await timelineStore.updateEvent(id: event.id, eventText: newText, eventType: nil) }
                }
            }
            .padding(.bottom, 18)
        }
    }

    /// Point the timeline at the currently-selected character and (re)load it.
    /// The 角色 segment owns selection; the timeline just mirrors it.
    private func syncTimelineToSelectedCharacter() async {
        let target = charactersStore.selectedCharacterId
            ?? charactersStore.characters.first?.id
        guard let target else { return }
        if timelineStore.characterId != target {
            timelineStore.setCharacter(target)
            await timelineStore.loadInitial()
        } else if timelineStore.events.isEmpty {
            await timelineStore.loadInitial()
        }
    }
}

// MARK: - Inline-editable event text

private struct IOSTimelineText: View {
    let event: TimelineEvent
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(LWColor.bodyText)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onSubmit { commit() }
            } else {
                Text(event.eventText)
                    .font(.system(size: 13.5)).foregroundStyle(LWColor.bodyText)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEdit() }
            }
        }
    }

    private func startEdit() {
        draft = event.eventText
        editing = true
        DispatchQueue.main.async { focused = true }
    }
    private func commit() {
        editing = false
        if draft != event.eventText && !draft.isEmpty { onCommit(draft) }
    }
}
#endif
