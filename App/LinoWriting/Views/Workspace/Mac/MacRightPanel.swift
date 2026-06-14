#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — macOS workspace right column (5-tab panel).
///
/// Handoff `LinoWriting.dc.html` 工作台 RIGHT (~326, `.lwSidebar`):
/// 角色 / 大纲 / 时间线 / 梗概 / 设定. macOS-only.
enum MacRightPanelTab: String, CaseIterable, Identifiable {
    case characters, outline, timeline, summaries, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .characters: return "角色"
        case .outline: return "大纲"
        case .timeline: return "时间线"
        case .summaries: return "梗概"
        case .settings: return "设定"
        }
    }
}

struct MacRightPanel: View {
    let book: Book
    @Binding var tab: MacRightPanelTab

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .lwSidebar()
        .overlay(alignment: .leading) {
            Rectangle().fill(LWMetrics.hairlineLight).frame(width: 0.5)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MacRightPanelTab.allCases) { t in
                let selected = tab == t
                Button { tab = t } label: {
                    Text(t.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .white : LWColor.secondaryText2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            selected ? AnyShapeStyle(LWColor.accentGradient) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .onHover { pointer($0) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .characters: MacCharacterTab(book: book)
        case .outline: MacOutlineTab(book: book)
        case .timeline: MacTimelineTab()
        case .summaries: MacSummariesTab()
        case .settings: MacBookSettingsTab(book: book)
        }
    }
}
#endif
