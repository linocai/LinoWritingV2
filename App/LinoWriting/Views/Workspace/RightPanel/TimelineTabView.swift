import SwiftUI

public struct TimelineTabView: View {
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var timelineStore: TimelineStore

    /// PROJECT_PLAN §5.C — id of the event the user just clicked the trash
    /// can on. Drives the confirmation alert. `nil` = no alert showing.
    @State private var pendingDelete: TimelineEvent?

    /// id of the event currently in inline-edit mode (only one at a time).
    /// Tracking it at the parent so clicking row B exits row A automatically.
    @State private var editingEventId: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            list
        }
        .onAppear { initializeIfNeeded() }
        .onChange(of: charactersStore.characters.map(\.id)) { _, _ in initializeIfNeeded() }
        // C-tl reviewer 🟡 #2: use a real two-way binding so system-level
        // dismiss paths (Esc / accessibility / tap-outside on iOS) actually
        // clear pendingDelete. The previous `.constant(...)` swallowed those
        // signals, leaving stale state that would re-fire the alert on the
        // next pendingDelete assignment.
        .alert(
            "删除这条事件？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { presenting in if !presenting { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { event in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = event
                pendingDelete = nil
                Task { await timelineStore.deleteEvent(id: target.id) }
            }
        } message: { _ in
            Text("该操作不可撤销。")
        }
    }

    private var picker: some View {
        HStack(spacing: 8) {
            if charactersStore.characters.isEmpty {
                Text("还没有角色")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { timelineStore.characterId ?? "" },
                    set: { newId in
                        guard !newId.isEmpty else { return }
                        timelineStore.setCharacter(newId)
                        Task { await timelineStore.loadInitial() }
                    }
                )) {
                    ForEach(charactersStore.characters) { c in
                        Text(c.name).tag(c.id)
                    }
                }
                .labelsHidden()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if timelineStore.isLoading && timelineStore.events.isEmpty {
            ProgressView().padding(20)
        } else if timelineStore.events.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("这个角色还没有事件。完成第一章后会自动累积。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(timelineStore.events) { event in
                        TimelineEventRow(
                            event: event,
                            isEditing: editingEventId == event.id,
                            onStartEdit: { editingEventId = event.id },
                            onCancelEdit: {
                                if editingEventId == event.id { editingEventId = nil }
                            },
                            onCommitEdit: { newText in
                                editingEventId = nil
                                let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty, trimmed != event.eventText else { return }
                                Task {
                                    await timelineStore.updateEvent(
                                        id: event.id,
                                        eventText: trimmed,
                                        eventType: nil
                                    )
                                }
                            },
                            onDelete: { pendingDelete = event }
                        )
                    }
                    if timelineStore.hasMore {
                        Button("加载更多") {
                            Task { await timelineStore.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding(12)
            }
        }
    }

    private func initializeIfNeeded() {
        guard timelineStore.characterId == nil, let first = charactersStore.characters.first else { return }
        timelineStore.setCharacter(first.id)
        Task { await timelineStore.loadInitial() }
    }
}

// MARK: - Row

/// One row inside the timeline list. Pulled out as its own View so the
/// `@State` hover flag (macOS) and the inline-edit `TextEditor` keep their
/// own per-row identity across LazyVStack diffing.
private struct TimelineEventRow: View {
    let event: TimelineEvent
    let isEditing: Bool
    let onStartEdit: () -> Void
    let onCancelEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onDelete: () -> Void

    /// macOS hover state for the right-side trash button. iOS routes the
    /// delete affordance through `.swipeActions` instead (see modifier).
    @State private var isHovered: Bool = false

    /// Local working copy of the event text while in edit mode. Reset on
    /// every enter-into-edit via the `.onChange(isEditing)` below so a
    /// previous abandoned draft doesn't leak.
    @State private var draft: String = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("第 \(event.chapterIndex) 章")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Text(event.eventType.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if event.editedAt != nil {
                    Text("已编辑")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                        .help("这条事件被用户改过")
                }
                Spacer()
                // PROJECT_PLAN §5.C — right-side delete affordance only
                // appears on hover (macOS). On iOS the swipe-action below
                // is the equivalent. Hidden during inline edit so the row
                // doesn't fight the editor for the click area.
                #if os(macOS)
                if isHovered && !isEditing {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.red.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("删除这条事件")
                    .transition(.opacity)
                }
                #endif
            }

            if isEditing {
                // Inline editor: TextEditor for multi-line freedom.
                // C-tl reviewer 🟡 #1: TextEditor intercepts Return for
                // newlines, so .onSubmit never fires. Saving is therefore
                // **on blur** (focus loss) — matches the frozen-field
                // InlineEditableText commit-on-blur contract. Esc cancels
                // on macOS via .onExitCommand. UI hint below makes the
                // contract explicit so the user isn't confused why Enter
                // doesn't seem to do anything.
                editor
                Text("失焦自动保存 · Esc 取消(macOS)· Return 换行")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(event.eventText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        draft = event.eventText
                        onStartEdit()
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
        .animation(.smooth(duration: 0.15), value: isHovered)
        .onChange(of: isEditing) { _, editing in
            if editing { draft = event.eventText }
        }
        #if !os(macOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
        #endif
    }

    /// Inline editor pane. Pulled into its own ViewBuilder so the
    /// `onExitCommand` modifier (macOS-only) can be platform-gated without
    /// duplicating the rest of the TextEditor setup. On iOS Esc is delivered
    /// via the hardware keyboard if any; the blur path (`editorFocused`
    /// going false) already covers the soft-keyboard "tap outside" case.
    @ViewBuilder
    private var editor: some View {
        let base = TextEditor(text: $draft)
            .font(.callout)
            .frame(minHeight: 60)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
            )
            .focused($editorFocused)
            .onAppear { editorFocused = true }
            // No .onSubmit here — TextEditor intercepts Return for newlines.
            // Save happens on blur (editorFocused -> false, below) per
            // C-tl reviewer 🟡 #1.
            .onChange(of: editorFocused) { _, focused in
                // Blur === auto-save (skip if the user already hit Esc on
                // macOS, which we surface via .onExitCommand below).
                if !focused, isEditing { onCommitEdit(draft) }
            }
        #if os(macOS)
        base.onExitCommand { onCancelEdit() }
        #else
        base
        #endif
    }
}
