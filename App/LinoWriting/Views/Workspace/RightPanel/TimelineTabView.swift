import SwiftUI

public struct TimelineTabView: View {
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var timelineStore: TimelineStore

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            list
        }
        .onAppear { initializeIfNeeded() }
        .onChange(of: charactersStore.characters.map(\.id)) { _, _ in initializeIfNeeded() }
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
                        eventRow(event)
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

    private func eventRow(_ event: TimelineEvent) -> some View {
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
            }
            Text(event.eventText)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func initializeIfNeeded() {
        guard timelineStore.characterId == nil, let first = charactersStore.characters.first else { return }
        timelineStore.setCharacter(first.id)
        Task { await timelineStore.loadInitial() }
    }
}
