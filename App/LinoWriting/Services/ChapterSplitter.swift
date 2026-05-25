import Foundation

/// A single chapter extracted by `ChapterSplitter` from a multi-chapter
/// paste in batch-import mode (PROJECT_PLAN v0.7 §5.O).
///
/// `index` is **local** to the paste (0-based), not the eventual chapter
/// index assigned by the backend — the backend auto-increments
/// `chapters.index` on every `POST /chapters` so the source order is what
/// matters here. `title` is optional because some separators (e.g. bare
/// `===` lines) don't carry a label; in that case the backend keeps the
/// chapter title null and the user can rename later.
public struct ParsedChapter: Hashable, Identifiable, Sendable {
    public let index: Int
    public let title: String?
    public let body: String

    public init(index: Int, title: String?, body: String) {
        self.index = index
        self.title = title
        self.body = body
    }

    /// SwiftUI list identity. Local `index` + a hash of the title keep
    /// list rows stable across edits to other chapters' titles in the
    /// preview (the hash of *this* title only changes when *this* row
    /// changes, so the others don't re-render).
    public var id: String { "\(index)-\(title?.hashValue ?? 0)" }

    public var characterCount: Int { body.count }
}

/// Splits a multi-chapter paste into individual `ParsedChapter`s for
/// batch import (PROJECT_PLAN v0.7 §5.O.2).
///
/// The splitter tries a small set of common chapter separators, in
/// priority order, and stops at the **first** pattern that produces
/// more than one chapter. This avoids the trap where a doc uses
/// `第X章` headings but also happens to contain a `===` line inside
/// the body — picking the wrong separator would shred a single
/// chapter into noise.
///
/// If no pattern matches, the splitter returns a single `ParsedChapter`
/// containing the whole text (title `nil`). Callers can detect this
/// case via `result.count == 1` and surface it as "未检测到章节分隔符,
/// 将作为单章导入" so the user knows what happened.
public enum ChapterSplitter {

    /// One entry in the splitter's pattern table.
    ///
    /// `pattern` is the regex matched line-by-line; `minChapters` is the
    /// minimum number of resulting chapters needed to accept this
    /// pattern as the winning split. CJK / English chapter-label
    /// patterns are semantically explicit, so a *single* matching line
    /// is enough to call it a "split" (the text before the first
    /// boundary gets treated as discardable front-matter — book title
    /// page, preface, blank lines, etc.). Thematic-break patterns
    /// (`===` / `---`) require ≥ 2 matches because one stray bar line
    /// inside an otherwise normal manuscript shouldn't shred it.
    struct Pattern {
        let regex: String
        let minChapters: Int
    }

    /// Regex patterns tried in order. Each pattern matches **a single
    /// line** that acts as a chapter boundary; the splitter consumes
    /// that line as the title-source and treats everything between
    /// consecutive boundaries as the chapter body.
    ///
    /// Order matters:
    ///   1. CJK章节 with subtitle (`第三章 山洞夜话` / `第3章·开端`)
    ///   2. CJK章节 bare (`第三章` / `第 3 章`)
    ///   3. English `Chapter N` (with optional subtitle)
    ///   4. `===` thematic break (3+ equals)
    ///   5. `---` markdown thematic break (3+ hyphens)
    static let patterns: [Pattern] = [
        // 1. 第X章 + 副标题(可选副标题分隔符:空格 / 全角空格 / 中点 / 顿号 / 冒号 / 破折号)
        //    e.g. "第三章 山洞" / "第3章·开端" / "第十二章:夜行"
        Pattern(
            regex: #"^\s*第[一二三四五六七八九十百千万零〇两0-9]+章[ 　·、:：—\-].*\S.*$"#,
            minChapters: 1
        ),
        // 2. 第X章 裸标(行末仅有标题词,无副标题)
        //    e.g. "第三章" / "第 3 章"
        Pattern(
            regex: #"^\s*第[一二三四五六七八九十百千万零〇两0-9]+章\s*$"#,
            minChapters: 1
        ),
        // 3. Chapter N (with optional subtitle)
        //    e.g. "Chapter 1" / "Chapter 12: Beginning"
        Pattern(
            regex: #"^\s*Chapter\s+\d+([\s:.\-—].*)?$"#,
            minChapters: 1
        ),
        // 4. ===  ===  (≥ 2 to avoid a stray bar shredding chapter 1)
        Pattern(
            regex: #"^\s*={3,}\s*$"#,
            minChapters: 2
        ),
        // 5. ---  ---  (≥ 2 to avoid a markdown HR splitting a chapter)
        Pattern(
            regex: #"^\s*-{3,}\s*$"#,
            minChapters: 2
        )
    ]

    public static func split(_ text: String) -> [ParsedChapter] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Preserve line indices into the original text so the slices we
        // emit match the user's exact whitespace within each chapter
        // body (one chapter ending with a blank line should keep that
        // blank line; we only strip the surrounding whitespace from the
        // final assembled body).
        let lines = text.components(separatedBy: "\n")

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern.regex,
                options: [.caseInsensitive]
            ) else { continue }

            // Collect line indices that match this boundary pattern.
            var boundaries: [Int] = []
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    boundaries.append(i)
                }
            }

            guard !boundaries.isEmpty else { continue }

            let chapters = assemble(lines: lines, boundaries: boundaries)
            if chapters.count >= pattern.minChapters { return chapters }
        }

        // Fallback: no useful separator → single chapter, whole text.
        return [ParsedChapter(index: 0, title: nil, body: trimmed)]
    }

    /// Given source lines and the indices of boundary lines, build the
    /// `ParsedChapter` list. Boundary lines themselves are consumed as
    /// the *next* chapter's title source (i.e. the boundary line at
    /// index `k` belongs to chapter starting at line `k`, body is
    /// `lines[k+1 ... nextBoundary-1]`).
    ///
    /// Any text **before** the first boundary is discarded — this is
    /// almost always front-matter (book title page, preface marker,
    /// blank lines) that the user doesn't want imported as chapter 1.
    /// Edge case: a paste where the first non-empty line is itself a
    /// boundary works correctly because `boundaries[0] == 0` and the
    /// "before" slice is empty.
    private static func assemble(lines: [String], boundaries: [Int]) -> [ParsedChapter] {
        var result: [ParsedChapter] = []
        for (i, boundaryIdx) in boundaries.enumerated() {
            let nextBoundary = (i + 1 < boundaries.count) ? boundaries[i + 1] : lines.count
            // body = lines after the boundary, up to (but not including) the next boundary
            let bodyStart = boundaryIdx + 1
            guard bodyStart <= nextBoundary else { continue }
            let bodyLines = Array(lines[bodyStart..<nextBoundary])
            let body = bodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip chapters whose body is empty — usually two boundary
            // lines back-to-back (e.g. "===" then "===" on next line).
            if body.isEmpty { continue }
            let title = extractTitle(from: lines[boundaryIdx])
            result.append(ParsedChapter(index: result.count, title: title, body: body))
        }
        return result
    }

    /// Extract the human-facing title from a boundary line.
    ///
    /// For CJK 第X章 lines we strip the "第X章" prefix and any leading
    /// separator (space / 全角空格 / 中点 / 顿号 / 冒号 / 破折号),
    /// keeping the subtitle. For thematic breaks (`===` / `---`) there
    /// is no title text so we return `nil`. For `Chapter N` lines we
    /// keep the whole line (including "Chapter N") because English
    /// chapter labels are typically expected to read that way in the
    /// final book.
    private static func extractTitle(from line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespaces)
        // Pure thematic break → no title
        if s.range(of: #"^={3,}$"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"^-{3,}$"#, options: .regularExpression) != nil { return nil }

        // CJK 第X章 ... — strip the prefix to keep just the subtitle.
        // If no subtitle is left (bare "第三章"), keep the whole label
        // so the sidebar isn't blank.
        if let match = s.range(
            of: #"^第[一二三四五六七八九十百千万零〇两0-9]+章"#,
            options: .regularExpression
        ) {
            let after = s[match.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " 　·、:：—-\t"))
            return after.isEmpty ? s : after
        }

        // Chapter N — keep as-is.
        if s.range(of: #"^Chapter\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return s
        }

        return s.isEmpty ? nil : s
    }
}
