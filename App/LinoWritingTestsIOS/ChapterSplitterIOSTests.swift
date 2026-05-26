import XCTest
@testable import LinoWriting

/// R-4 (v0.8) — iOS Simulator re-verification of ``ChapterSplitter``.
///
/// The macOS bundle already covers ``ChapterSplitter`` extensively
/// (`LinoWritingTests/ChapterSplitterTests.swift`). The iOS bundle re-runs
/// a focused subset to catch any platform-specific runtime differences in
/// Foundation's `String` / `NSRegularExpression` behaviour that the macOS
/// pass would miss — for example, ICU version skew between macOS 14 and
/// iOS 17 has historically tripped up Chinese normalisation forms (NFC vs
/// NFKC). These four tests are intentionally small and stable.
final class ChapterSplitterIOSTests: XCTestCase {

    // MARK: - 中文分章

    func test_splits_chinese_chapter_markers_第一章() {
        let text = """
        第一章 起航
        第一段正文。

        第二章 抵岸
        第二段正文。
        """

        let chapters = ChapterSplitter.split(text)

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "起航")
        XCTAssertEqual(chapters[1].title, "抵岸")
    }

    func test_splits_chinese_chapter_markers_第1章() {
        let text = """
        第1章 起点
        正文 A。

        第2章 中点
        正文 B。
        """

        let chapters = ChapterSplitter.split(text)

        XCTAssertEqual(chapters.count, 2)
        // ChapterSplitter indices are 0-based (see macOS baseline tests);
        // the import step assigns the final 1-based chapter numbers.
        XCTAssertEqual(chapters[0].index, 0)
        XCTAssertEqual(chapters[1].index, 1)
        XCTAssertEqual(chapters[0].title, "起点")
        XCTAssertEqual(chapters[1].title, "中点")
    }

    // MARK: - 边界

    func test_single_chapter_no_marker_returns_one_chapter() {
        let text = "一段没有任何章节标记的纯正文。"

        let chapters = ChapterSplitter.split(text)

        // Spec: no marker → entire input becomes a single anonymous chapter.
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].body, text)
    }

    func test_empty_input_returns_empty_array() {
        let chapters = ChapterSplitter.split("")
        XCTAssertEqual(chapters.count, 0)
    }
}
