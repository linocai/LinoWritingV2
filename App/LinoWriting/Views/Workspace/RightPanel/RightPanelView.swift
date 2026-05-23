import SwiftUI

public enum RightPanelTab: String, CaseIterable {
    case characters, timeline, summaries, world

    public var label: String {
        switch self {
        case .characters: return "角色卡"
        case .timeline: return "时间线"
        case .summaries: return "摘要"
        case .world: return "世界设定"
        }
    }

    public var systemImage: String {
        switch self {
        case .characters: return "person.crop.rectangle.stack"
        case .timeline: return "clock"
        case .summaries: return "doc.text"
        case .world: return "globe.asia.australia"
        }
    }
}

public struct RightPanelView: View {
    @Binding public var tab: RightPanelTab

    public init(tab: Binding<RightPanelTab>) { self._tab = tab }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .characters: CharacterCardListView()
        case .timeline: TimelineTabView()
        case .summaries: SummariesTabView()
        case .world: WorldSettingTabView()
        }
    }
}
