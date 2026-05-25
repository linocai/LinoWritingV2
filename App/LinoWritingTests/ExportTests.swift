import XCTest
@testable import LinoWriting

/// v0.7 §5.F — frontend export tests.
///
/// Covers four areas:
/// 1. ``ExportFormat`` static helpers (fileExtension / contentType).
/// 2. ``APIClient.parseSuggestedFilename`` static parser (RFC 5987
///    + plain ``filename=`` fallback).
/// 3. ``MockAPIClient.exportBook`` / ``exportChapter`` capture the
///    arguments correctly — guards against a future encoder change
///    silently dropping ``include_drafts`` or the format query.
/// 4. End-to-end happy path through the mock for both endpoints.
@MainActor
final class ExportTests: XCTestCase {

    // MARK: - ExportFormat

    func test_exportFormat_fileExtension_mapsToBackendShape() {
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.txt.fileExtension, "txt")
    }

    func test_exportFormat_contentType_matchesBackendMediaType() {
        XCTAssertEqual(ExportFormat.markdown.contentType, "text/markdown")
        XCTAssertEqual(ExportFormat.txt.contentType, "text/plain")
    }

    func test_exportFormat_rawValue_matchesBackendLiteral() {
        // The backend's FastAPI `Literal["markdown", "txt"]` accepts
        // exactly these two strings; mismatch would 422 every export.
        XCTAssertEqual(ExportFormat.markdown.rawValue, "markdown")
        XCTAssertEqual(ExportFormat.txt.rawValue, "txt")
    }

    // MARK: - Content-Disposition parsing

    func test_parseSuggestedFilename_prefersRfc5987EncodedForm() throws {
        // Encoded form represents `夜雨长歌.md` (per `urllib.quote` semantics).
        let header = "attachment; filename=\"?.md\"; filename*=UTF-8''%E5%A4%9C%E9%9B%A8%E9%95%BF%E6%AD%8C.md"
        let url = URL(string: "https://example.test/api/v1/books/x/export")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Disposition": header])!
        let parsed = APIClient.parseSuggestedFilename(from: resp)
        XCTAssertEqual(parsed, "夜雨长歌.md")
    }

    func test_parseSuggestedFilename_fallsBackToPlainFilename() throws {
        let header = "attachment; filename=\"foo.txt\""
        let url = URL(string: "https://example.test/api/v1/books/x/export")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Disposition": header])!
        let parsed = APIClient.parseSuggestedFilename(from: resp)
        XCTAssertEqual(parsed, "foo.txt")
    }

    func test_parseSuggestedFilename_returnsNilOnMissingHeader() throws {
        let url = URL(string: "https://example.test/api/v1/books/x/export")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: [:])!
        XCTAssertNil(APIClient.parseSuggestedFilename(from: resp))
    }

    // MARK: - APIClient → MockAPIClient happy paths

    func test_mock_exportBook_capturesFormatAndIncludeDrafts() async throws {
        let mock = MockAPIClient()
        let book = try await mock.createBook(BookCreateRequest(title: "夜雨长歌", coverColor: nil))

        let (data, filename) = try await mock.exportBook(
            id: book.id, format: .markdown, includeDrafts: false
        )

        XCTAssertEqual(mock.calls.last, "exportBook")
        XCTAssertEqual(mock.lastExportBookCall?.id, book.id)
        XCTAssertEqual(mock.lastExportBookCall?.format, .markdown)
        XCTAssertEqual(mock.lastExportBookCall?.includeDrafts, false)
        XCTAssertEqual(filename, "夜雨长歌.md")
        XCTAssertEqual(String(data: data, encoding: .utf8), "# 夜雨长歌\n")
    }

    func test_mock_exportBook_includeDrafts_true_passesThrough() async throws {
        let mock = MockAPIClient()
        let book = try await mock.createBook(BookCreateRequest(title: "测试", coverColor: nil))

        _ = try await mock.exportBook(id: book.id, format: .txt, includeDrafts: true)
        XCTAssertEqual(mock.lastExportBookCall?.format, .txt)
        XCTAssertEqual(mock.lastExportBookCall?.includeDrafts, true)
    }

    func test_mock_exportBook_unknownId_throwsNotFound() async {
        let mock = MockAPIClient()
        do {
            _ = try await mock.exportBook(
                id: "nonexistent", format: .markdown, includeDrafts: false
            )
            XCTFail("expected notFound to be thrown")
        } catch let error as AppError {
            if case .notFound = error {
                // ok
            } else {
                XCTFail("expected .notFound, got \(error)")
            }
        } catch {
            XCTFail("expected AppError, got \(error)")
        }
    }

    func test_mock_exportChapter_capturesIdAndFormat() async throws {
        let mock = MockAPIClient()
        let book = try await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: nil, title: "山洞")
        )

        let (data, filename) = try await mock.exportChapter(id: chapter.id, format: .markdown)

        XCTAssertEqual(mock.calls.last, "exportChapter")
        XCTAssertEqual(mock.lastExportChapterCall?.id, chapter.id)
        XCTAssertEqual(mock.lastExportChapterCall?.format, .markdown)
        XCTAssertEqual(filename, "第1章·山洞.md")
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("第1章·山洞"))
    }

    func test_mock_exportChapter_untitledFallsBackToChapterNumber() async throws {
        let mock = MockAPIClient()
        let book = try await mock.createBook(BookCreateRequest(title: "B", coverColor: nil))
        let chapter = try await mock.createChapter(
            bookId: book.id,
            ChapterCreateRequest(userPrompt: nil, title: nil)
        )

        let (_, filename) = try await mock.exportChapter(id: chapter.id, format: .txt)
        XCTAssertEqual(filename, "第1章.txt")
    }
}
