import XCTest
@testable import LinoWriting

/// Coverage for the `ChapterSplitter` helper (PROJECT_PLAN v0.7 §5.O).
///
/// The splitter feeds the batch-import preview and submit pipeline, so
/// every regex pattern and the fallback path need a concrete test —
/// otherwise a regex tweak (e.g. accidentally swallowing CJK numerals)
/// would silently shred multi-chapter pastes in production.
final class ChapterSplitterTests: XCTestCase {

    // MARK: 中文章节分隔符

    func test_split_chineseChaptersWithSubtitle() {
        let text = """
        第一章 山洞
        山洞里很黑。
        洞口有水声。

        第二章 河边
        小马在河边喝水。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "山洞")
        XCTAssertTrue(chapters[0].body.contains("山洞里很黑"))
        XCTAssertEqual(chapters[1].title, "河边")
        XCTAssertTrue(chapters[1].body.contains("小马在河边喝水"))
        XCTAssertEqual(chapters[0].index, 0)
        XCTAssertEqual(chapters[1].index, 1)
    }

    func test_split_chineseChapters_numericAndCJKDigits() {
        // Mixes "第10章" with "第三十二章" — both should match the same pattern.
        let text = """
        第10章 开端
        这是开端。

        第三十二章 高潮
        这是高潮。

        第100章 终章
        这是终章。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "开端")
        XCTAssertEqual(chapters[1].title, "高潮")
        XCTAssertEqual(chapters[2].title, "终章")
    }

    func test_split_chineseChapters_bareNoSubtitle() {
        // Bare "第X章" lines with no subtitle should still split, with
        // the boundary line itself preserved as the title (so the
        // sidebar isn't blank).
        let text = """
        第一章

        第一章的正文。

        第二章

        第二章的正文。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章")
        XCTAssertEqual(chapters[1].title, "第二章")
        XCTAssertTrue(chapters[0].body.contains("第一章的正文"))
        XCTAssertTrue(chapters[1].body.contains("第二章的正文"))
    }

    // MARK: 英文 Chapter

    func test_split_englishChapters() {
        let text = """
        Chapter 1
        The cave was dark.

        Chapter 2: The River
        The pony drank.
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Chapter 1")
        XCTAssertEqual(chapters[1].title, "Chapter 2: The River")
        XCTAssertTrue(chapters[0].body.contains("cave"))
        XCTAssertTrue(chapters[1].body.contains("pony"))
    }

    // MARK: === / --- 分隔符

    func test_split_equalsSeparator() {
        let text = """
        ===
        第一段独立的文本。
        ===
        第二段独立的文本。
        ===
        第三段独立的文本。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 3)
        // === 分隔符不携带标题
        XCTAssertNil(chapters[0].title)
        XCTAssertNil(chapters[1].title)
        XCTAssertNil(chapters[2].title)
        XCTAssertTrue(chapters[0].body.contains("第一段"))
        XCTAssertTrue(chapters[2].body.contains("第三段"))
    }

    func test_split_dashSeparator() {
        let text = """
        ---
        Body one.
        ---
        Body two.
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertNil(chapters[0].title)
        XCTAssertEqual(chapters[0].body, "Body one.")
        XCTAssertEqual(chapters[1].body, "Body two.")
    }

    // MARK: Fallback / 空文本

    func test_split_emptyText_returnsEmpty() {
        XCTAssertEqual(ChapterSplitter.split("").count, 0)
        XCTAssertEqual(ChapterSplitter.split("   \n\n   ").count, 0)
    }

    func test_split_noSeparator_returnsSingleChapter() {
        let text = """
        这是一段没有分隔符的文字。
        总共有两行。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertNil(chapters[0].title)
        XCTAssertTrue(chapters[0].body.contains("这是一段没有分隔符的文字"))
        XCTAssertTrue(chapters[0].body.contains("总共有两行"))
    }

    // MARK: Priority — 高优先级正确赢

    /// If a doc mixes CJK 章节 labels AND ASCII separators, the CJK
    /// pattern wins because it appears first in `ChapterSplitter.patterns`.
    /// Otherwise a stray `===` line inside chapter 1's body would split
    /// it into two false positives.
    func test_split_chineseChaptersBeatsEqualsLine() {
        let text = """
        第一章 引子
        引子内容。
        ===
        引子还在继续(这一行的 === 是文档里的横线,不该当成分隔符)。

        第二章 正文
        正文内容。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2, "CJK 章节标记应优先于 === 分隔")
        XCTAssertEqual(chapters[0].title, "引子")
        XCTAssertTrue(chapters[0].body.contains("引子还在继续"),
                      "引子里的 === 行应作为引子的正文保留")
        XCTAssertEqual(chapters[1].title, "正文")
    }

    // MARK: Body trimming

    func test_split_chapterBodyTrimsSurroundingWhitespace() {
        // Boundary line followed by blank lines — body should not
        // include those blanks at the start.
        let text = """
        第一章 山洞


        山洞里很黑。



        第二章 河边


        小马喝水。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].body, "山洞里很黑。",
                       "首尾空行应被 trim 掉")
        XCTAssertEqual(chapters[1].body, "小马喝水。")
    }

    // MARK: Front-matter discarded

    /// Text before the very first boundary line is treated as
    /// front-matter (book title page, preface, blank lines) and
    /// discarded. Important so a user pasting "《书名》\n作者: …\n\n第一
    /// 章…" doesn't end up with chapter 0 = the book metadata.
    func test_split_discardsFrontMatterBeforeFirstBoundary() {
        let text = """
        《我的故事》
        作者：小马

        第一章 山洞
        山洞里很黑。
        """

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "山洞")
        XCTAssertFalse(chapters[0].body.contains("《我的故事》"),
                       "前置元数据不应被吃进章节正文")
    }

    // MARK: 大批量

    func test_split_largePaste_50Chapters() {
        // Synthesize 50 chapters and confirm we got 50 ParsedChapters
        // with sequential local indices.
        var lines: [String] = []
        for n in 1...50 {
            lines.append("第\(n)章 标题\(n)")
            lines.append("这是第\(n)章的正文。")
            lines.append("")
        }
        let text = lines.joined(separator: "\n")

        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 50)
        for (i, ch) in chapters.enumerated() {
            XCTAssertEqual(ch.index, i)
            XCTAssertEqual(ch.title, "标题\(i + 1)")
            XCTAssertTrue(ch.body.contains("第\(i + 1)章的正文"))
        }
    }
}
