#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 时间线 tab. Selected character's events on a vertical
/// axis; each = event_type label (6 coloured) + chapter index + "已编辑" marker
/// (edited_at non-null) + delete; text inline edit (`updateTimelineEvent`).
/// **No add button** — only the Extractor writes events. macOS-only.
struct MacTimelineTab: View {
    @EnvironmentObject var timelineStore: TimelineStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var pendingDelete: TimelineEvent?

    private var ownerName: String {
        guard let id = timelineStore.characterId else { return "未选择角色" }
        return charactersStore.characters.first(where: { $0.id == id })?.name ?? "角色"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(ownerName) 的时间线 · 由抽取 Agent 写入")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                .padding(.vertical, 6).padding(.horizontal, 2)

            if timelineStore.events.isEmpty {
                emptyState
            } else {
                ForEach(Array(timelineStore.events.enumerated()), id: \.element.id) { idx, event in
                    eventRow(event, isLast: idx == timelineStore.events.count - 1)
                }
            }
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
        VStack(spacing: 4) {
            Text("暂无时间线事件").font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
            Text("完成章节抽取后会自动出现在这里")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func eventRow(_ event: TimelineEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Circle().fill(LWColor.accentStart).frame(width: 9, height: 9).padding(.top, 5)
                if !isLast {
                    Rectangle().fill(LWColor.accentStart.opacity(0.2)).frame(width: 1.5)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(event.eventType.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LWColor.accentText)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(LWColor.accentStart.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("第 \(event.chapterIndex) 章")
                        .font(.system(size: 11)).foregroundStyle(LWColor.mutedText3)
                    if event.editedAt != nil {
                        Text("已编辑").font(.system(size: 10)).foregroundStyle(LWColor.warning)
                    }
                    Spacer()
                    Button { pendingDelete = event } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(LWColor.danger)
                    }
                    .buttonStyle(.plain).onHover { pointer($0) }
                }
                MacTimelineText(event: event) { newText in
                    Task { await timelineStore.updateEvent(id: event.id, eventText: newText, eventType: nil) }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

private struct MacTimelineText: View {
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
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.bodyText)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onSubmit { commit() }
            } else {
                Text(event.eventText)
                    .font(.system(size: 13)).foregroundStyle(LWColor.bodyText)
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
