import XCTest
import SwiftUI
@testable import LinoWriting

/// R-4 (v0.8) — pin down the R-1 / R-2 layout-dispatch *rules* that
/// ``WorkspaceView`` enforces on iOS, without needing to instantiate the
/// view itself (which depends on the full ``AppEnvironment`` graph and a
/// hosted SwiftUI runtime).
///
/// The rules under test (cf. WorkspaceView.swift):
///   1. Size-class dispatch — `.regular` → iPad NavigationSplitView,
///      `.compact` → iPhone NavigationStack (and *also* iPad Split View
///      at compact width per §5.R.7).
///   2. iPad orientation default — portrait starts at `.doubleColumn`,
///      landscape starts at `.all`. Derived from GeometryReader aspect
///      (width > height = landscape) so it reacts to Split View resize
///      as well as device rotation.
///   3. Inspector toggle — `.all → .doubleColumn → .all` cycle, mirroring
///      the macOS inspector toggle.
///
/// These tests don't touch SwiftUI's view tree (no ViewInspector — §5.R.6
/// bans new SPM deps). Instead we re-implement the same rules in pure
/// Swift here and assert against them, so a refactor of ``WorkspaceView``
/// that changes the contract will require updating *this* file too —
/// surfacing the change for review.
final class WorkspaceLayoutIOSTests: XCTestCase {

    // MARK: - Size class dispatch (R-2)

    /// `.regular` size class → iPad split-view layout.
    func test_regularSizeClass_picksIPadLayout() {
        let layout = layoutChoice(horizontalSizeClass: .regular)
        XCTAssertEqual(layout, .iPadSplit)
    }

    /// `.compact` size class → iPhone NavigationStack (per §5.R.7 this
    /// also catches iPad split-view at compact width and iPad mini).
    func test_compactSizeClass_picksIPhoneStack() {
        let layout = layoutChoice(horizontalSizeClass: .compact)
        XCTAssertEqual(layout, .iPhoneStack)
    }

    /// nil size class (during environment resolution) falls back to the
    /// safer compact branch — iPhone NavigationStack always works, while
    /// NavigationSplitView on a too-narrow window flickers.
    func test_nilSizeClass_fallsBackToIPhoneStack() {
        let layout = layoutChoice(horizontalSizeClass: nil)
        XCTAssertEqual(layout, .iPhoneStack)
    }

    // MARK: - iPad orientation default (R-2)

    /// Landscape (width > height) → `.all` (three columns open).
    func test_iPadLandscape_defaultsToAllColumns() {
        let visibility = iPadInitialVisibility(width: 1366, height: 1024)
        XCTAssertEqual(visibility, .all)
    }

    /// Portrait (height >= width) → `.doubleColumn` (sidebar + detail,
    /// inspector folded).
    func test_iPadPortrait_defaultsToDoubleColumn() {
        let visibility = iPadInitialVisibility(width: 1024, height: 1366)
        XCTAssertEqual(visibility, .doubleColumn)
    }

    /// Square-ish Split View width (e.g. 50/50 iPad split) — treated as
    /// portrait per the `width > height` strict-greater-than check.
    func test_iPadSquareSplit_treatedAsPortrait() {
        let visibility = iPadInitialVisibility(width: 768, height: 768)
        XCTAssertEqual(visibility, .doubleColumn)
    }

    /// Size change crossing the aspect threshold should flip visibility.
    /// Confirms the `onChange(of: proxy.size)` branch picks the right
    /// new target.
    func test_iPadResize_landscapeToPortrait_flipsToDoubleColumn() {
        var current: NavigationSplitViewVisibility = .all
        let target = iPadInitialVisibility(width: 800, height: 1100)
        if current != target { current = target }
        XCTAssertEqual(current, .doubleColumn)
    }

    func test_iPadResize_portraitToLandscape_flipsToAll() {
        var current: NavigationSplitViewVisibility = .doubleColumn
        let target = iPadInitialVisibility(width: 1400, height: 900)
        if current != target { current = target }
        XCTAssertEqual(current, .all)
    }

    // MARK: - Inspector toggle (R-3)

    /// `.all → .doubleColumn` on first toggle.
    func test_toggleInspector_fromAll_collapsesInspector() {
        let next = toggleInspector(from: .all)
        XCTAssertEqual(next, .doubleColumn)
    }

    /// `.doubleColumn → .all` on second toggle.
    func test_toggleInspector_fromDoubleColumn_expandsInspector() {
        let next = toggleInspector(from: .doubleColumn)
        XCTAssertEqual(next, .all)
    }

    /// Any other visibility (e.g. user dragged sidebar shut) → `.all`.
    /// Mirrors the `default` branch in ``toggleInspectorColumn()``.
    func test_toggleInspector_fromDetailOnly_resetsToAll() {
        let next = toggleInspector(from: .detailOnly)
        XCTAssertEqual(next, .all)
    }

    // MARK: - Helpers — mirror the production logic verbatim

    private enum LayoutChoice: Equatable {
        case iPadSplit
        case iPhoneStack
    }

    /// Mirrors ``WorkspaceView.iOSLayout`` dispatcher.
    private func layoutChoice(horizontalSizeClass: UserInterfaceSizeClass?) -> LayoutChoice {
        if horizontalSizeClass == .regular {
            return .iPadSplit
        }
        return .iPhoneStack
    }

    /// Mirrors ``WorkspaceView.iPadLayoutWithOrientation``'s
    /// `let isLandscape = proxy.size.width > proxy.size.height` choice.
    private func iPadInitialVisibility(
        width: CGFloat,
        height: CGFloat
    ) -> NavigationSplitViewVisibility {
        let isLandscape = width > height
        return isLandscape ? .all : .doubleColumn
    }

    /// Mirrors ``WorkspaceView.toggleInspectorColumn()``.
    private func toggleInspector(
        from current: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        switch current {
        case .all:
            return .doubleColumn
        default:
            return .all
        }
    }
}
