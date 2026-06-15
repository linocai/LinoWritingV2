#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P6) — 设置 · 调用日志.
///
/// Pixel-aligned to the handoff LOGS block (`LinoWriting iOS.dc.html`
/// L427–443): a "Agent 调用日志" section header, a horizontally-scrolling row of
/// filter chips (全部 / 写作 / 抽取 / 展开 → `all` / writer / extractor / expander),
/// then log cards each showing a status dot, the agent label, chapter label,
/// timestamp, a preview (error text in red when failed), and a 耗时 / token meta
/// line.
///
/// Binds the existing `AgentLogStore` (`GET /admin/logs` with `agent_name` +
/// `before` paging). Chapter labels resolve against `ChaptersStore` (the raw log
/// only carries `chapter_id`); unknown ids fall back to a short id tag.
/// Mirrors `MacLogsSettingsSection`'s logic.
struct IOSLogsSettingsSection: View {

    @EnvironmentObject private var store: AgentLogStore
    @EnvironmentObject private var chaptersStore: ChaptersStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chips
            list
                .padding(.horizontal, 16)
        }
        .task { if store.entries.isEmpty { await store.load() } }
    }

    private var header: some View {
        Text("Agent 调用日志")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LWColor.hex(0x3C3C43, opacity: 0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 7)
    }

    // MARK: - Filter chips

    private static let chipOrder: [AgentLogStore.AgentLogFilter] = [.all, .writer, .extractor, .expander]

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Self.chipOrder, id: \.self) { f in
                    chipButton(f)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func chipButton(_ f: AgentLogStore.AgentLogFilter) -> some View {
        let active = store.filter == f
        return Button {
            Task { await store.setFilter(f) }
        } label: {
            Text(chipLabel(f))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? LWColor.accentDeep : LWColor.secondaryText2)
                .frame(height: 30)
                .padding(.horizontal, 14)
                .background(
                    (active ? LWColor.accentStart.opacity(0.14) : .white.opacity(0.7)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(active ? LWColor.accentStart.opacity(0.35) : LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    /// Handoff filter labels (全部/写作/抽取/展开). These differ from
    /// `AgentLogFilter.displayName` ("提取"/"提纲展开") — the design wants the
    /// terser editorial words.
    private func chipLabel(_ f: AgentLogStore.AgentLogFilter) -> String {
        switch f {
        case .all: return "全部"
        case .writer: return "写作"
        case .extractor: return "抽取"
        case .expander: return "展开"
        case .adminReset: return "强制重置"
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if store.isLoading && store.entries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else if store.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "scroll").font(.system(size: 26, weight: .light)).foregroundStyle(LWColor.mutedText2)
                Text("还没有 Agent 调用记录").font(.system(size: 13)).foregroundStyle(LWColor.secondaryText)
                Text("展开提纲 / 写作 / 提取 后这里会出现条目。").font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 9) {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    IOSLogCard(entry: entry, chapterLabel: chapterLabel(for: entry.chapterId))
                        .onAppear {
                            if index == store.entries.count - 1 {
                                Task { await store.loadMore() }
                            }
                        }
                }
                if store.isLoading && !store.entries.isEmpty {
                    ProgressView().controlSize(.small).padding(.vertical, 8)
                } else if !store.hasMore {
                    Text("— 已是最早的记录 —")
                        .font(.system(size: 12))
                        .foregroundStyle(LWColor.mutedText3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    /// Resolve a `chapter_id` → "第 N 章 · 标题" using the loaded chapter list.
    private func chapterLabel(for id: String?) -> String? {
        guard let id else { return nil }
        guard let ch = chaptersStore.chapters.first(where: { $0.id == id }) else {
            return "章节 " + String(id.prefix(6))
        }
        if let title = ch.title, !title.isEmpty {
            return "第\(ch.index)章 · \(title)"
        }
        return "第\(ch.index)章"
    }
}

// MARK: - Log card

private struct IOSLogCard: View {
    let entry: AgentLog
    let chapterLabel: String?

    private var isError: Bool {
        if let e = entry.error, !e.isEmpty { return true }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top meta row
            HStack(spacing: 8) {
                Circle()
                    .fill(isError ? LWColor.danger : LWColor.success)
                    .frame(width: 7, height: 7)
                Text(IOSRoleVocab.label(rawAgentName: entry.agentName))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LWColor.bodyText)
                if let chapterLabel {
                    Text(chapterLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LWColor.mutedText3)
                        .lineLimit(1)
                }
                Spacer()
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.mutedText3)
            }
            .padding(.bottom, 6)

            // Preview (error red, else output→input)
            Text(previewText)
                .font(.system(size: 12.5))
                .foregroundStyle(isError ? LWColor.danger : LWColor.secondaryText2)
                .lineSpacing(2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 7)

            // Meta line
            HStack(spacing: 16) {
                Text("耗时 \(latencyText)")
                Text("token \(tokenText)")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(LWColor.mutedText3)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isError ? LWColor.danger.opacity(0.25) : Color.clear, lineWidth: 0.5)
        )
    }

    private var previewText: String {
        if isError, let e = entry.error { return e }
        if let o = entry.outputPreview, !o.isEmpty { return o }
        if let i = entry.inputPreview, !i.isEmpty { return i }
        return "（无预览）"
    }

    private var latencyText: String {
        guard let ms = entry.latencyMs else { return "—" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private var tokenText: String {
        "\(entry.tokensIn ?? 0) → \(entry.tokensOut ?? 0)"
    }
}
#endif
