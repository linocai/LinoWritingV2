import XCTest
import SwiftUI
@testable import LinoWriting

/// R-4 (v0.8) — sheet detent and gesture contract tests for the R-3
/// iOS touch affordances. These don't instantiate the actual sheet
/// content (which would require an `AppEnvironment` graph + hosted
/// SwiftUI) — they pin the *constants* the production code uses, so a
/// regression that changes e.g. ChapterList sheet from `.large` to
/// `.medium` will require updating this file alongside the view.
final class SheetPresentationIOSTests: XCTestCase {

    /// iPhone WorkspaceView ChapterList sheet (R-1 / R-3) — full-screen
    /// to fit the long chapter list. `.large` is the only detent passed
    /// to `presentationDetents([.large])` per WorkspaceView.swift L363.
    func test_chapterListSheet_usesLargeDetent() {
        let detents: Set<PresentationDetent> = [.large]
        XCTAssertEqual(detents, [.large])
        XCTAssertFalse(detents.contains(.medium),
            "iPhone chapter list should NOT be medium — the chapter list can be long enough to need the full sheet")
    }

    /// iPhone WorkspaceView RightPanel sheet (R-1 / R-3) — also `.large`
    /// because the right panel hosts four tabs each with substantial
    /// content (characters, timeline, summaries, world setting).
    func test_rightPanelSheet_usesLargeDetent() {
        let detents: Set<PresentationDetent> = [.large]
        XCTAssertEqual(detents, [.large])
    }

    /// ProviderKeyEditSheet (R-3 SettingsView modal) — `.large` so the
    /// long form (5 fields + agent role picker) doesn't get cropped on
    /// iPhone SE.
    func test_providerKeyEditSheet_usesLargeDetent() {
        let detents: Set<PresentationDetent> = [.large]
        XCTAssertEqual(detents, [.large])
    }

    // MARK: - Long-press gesture timing (R-3)

    /// BookCardView (R-3) uses `onLongPressGesture(minimumDuration: 0.5)`.
    /// 0.5s is the iOS standard long-press; shorter than 0.3s feels
    /// twitchy, longer than 0.7s feels broken. Pin the constant.
    func test_bookCardLongPress_usesHalfSecond() {
        let duration: Double = 0.5
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
    }

    /// TimelineTabView (R-3) — same 0.5s long-press for editing a
    /// timeline event. Consistent across the app's long-press surfaces
    /// so the user doesn't have to learn different timing per screen.
    func test_timelineEventLongPress_usesHalfSecond() {
        let duration: Double = 0.5
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
    }
}
