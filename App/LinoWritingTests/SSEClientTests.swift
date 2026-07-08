import XCTest
@testable import LinoWriting

final class SSEClientTests: XCTestCase {

    func test_parser_yieldsTokenAndDone() throws {
        let chapterJSON = """
        {"id":"c1","book_id":"b1","index":1,"title":null,"user_prompt":null,"structured_prompt":null,"draft_text":"全文","summary":null,"status":"draft_ready","created_at":"2026-05-22T10:00:00Z","updated_at":"2026-05-22T10:00:00Z"}
        """
        let stream = """
        : keepalive\n\nevent: started\ndata: {"chapter_id":"c1"}\n\nevent: token\ndata: {"text":"hello "}\n\nevent: token\ndata: {"text":"world"}\n\nevent: progress\ndata: {"chars":11}\n\nevent: done\ndata: {"chapter": \(chapterJSON)}\n\n
        """

        let parser = SSEParser()
        let events = parser.consume(buffer: stream)
        // Expected: started, token, token, progress, done — keepalive skipped.
        XCTAssertEqual(events.count, 5)
        if case .started(let id) = events[0] { XCTAssertEqual(id, "c1") } else { XCTFail() }
        if case .token(let t) = events[1] { XCTAssertEqual(t, "hello ") } else { XCTFail() }
        if case .token(let t) = events[2] { XCTAssertEqual(t, "world") } else { XCTFail() }
        if case .progress(let chars) = events[3] { XCTAssertEqual(chars, 11) } else { XCTFail() }
        if case .done(let chapter, let revision) = events[4] {
            XCTAssertEqual(chapter.status, .draftReady)
            XCTAssertNil(revision, "a done frame with no revision key must decode as nil")
        } else { XCTFail() }
    }

    /// v1.4.0 (MM) P4 — `revising` is a one-shot, empty-payload frame; `done`
    /// now carries an optional `revision` outcome string.
    func test_parser_yieldsRevisingAndDoneWithRevision() throws {
        let chapterJSON = """
        {"id":"c1","book_id":"b1","index":1,"title":null,"user_prompt":null,"structured_prompt":null,"draft_text":"压缩后全文","summary":null,"status":"draft_ready","created_at":"2026-05-22T10:00:00Z","updated_at":"2026-05-22T10:00:00Z"}
        """
        let stream = """
        event: started\ndata: {"chapter_id":"c1"}\n\nevent: revising\ndata: {}\n\nevent: done\ndata: {"chapter": \(chapterJSON), "revision": "revised"}\n\n
        """
        let parser = SSEParser()
        let events = parser.consume(buffer: stream)
        XCTAssertEqual(events.count, 3)
        if case .started = events[0] {} else { XCTFail("expected .started") }
        if case .revising = events[1] {} else { XCTFail("expected .revising") }
        if case .done(let chapter, let revision) = events[2] {
            XCTAssertEqual(chapter.draftText, "压缩后全文")
            XCTAssertEqual(revision, "revised")
        } else { XCTFail("expected .done with revision") }
    }

    /// A cancelled job's `done` frame omits the `revision` key entirely
    /// (never `null`) — must decode as `nil`, same as the pre-P4 shape.
    func test_parser_doneWithoutRevisionKey_decodesRevisionAsNil() throws {
        let chapterJSON = """
        {"id":"c1","book_id":"b1","index":1,"title":null,"user_prompt":null,"structured_prompt":null,"draft_text":"取消时的稿","summary":null,"status":"draft_ready","created_at":"2026-05-22T10:00:00Z","updated_at":"2026-05-22T10:00:00Z"}
        """
        let buffer = "event: done\ndata: {\"chapter\": \(chapterJSON)}\n\n"
        let parser = SSEParser()
        let events = parser.consume(buffer: buffer)
        XCTAssertEqual(events.count, 1)
        if case .done(_, let revision) = events[0] {
            XCTAssertNil(revision)
        } else { XCTFail("expected .done") }
    }

    func test_parser_handlesCRLFAndChunkedDelivery() {
        let parser = SSEParser()
        // First chunk: half of a message ending without blank line.
        let part1 = "event: token\r\ndata: {\"text\":\"abc\"}"
        let events1 = parser.consume(buffer: part1)
        XCTAssertTrue(events1.isEmpty)
        // Second chunk completes the message with a blank line, then starts a new one.
        let part2 = "\r\n\r\nevent: token\r\ndata: {\"text\":\"def\"}\r\n\r\n"
        let events2 = parser.consume(buffer: part2)
        XCTAssertEqual(events2.count, 2)
    }

    func test_parser_ignoresUnknownEvent() {
        let parser = SSEParser()
        let events = parser.consume(buffer: "event: nope\ndata: {\"x\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        if case .other(let name, _) = events[0] { XCTAssertEqual(name, "nope") }
        else { XCTFail("expected .other") }
    }

    func test_parser_errorEvent() {
        let parser = SSEParser()
        let payload = """
        {"error":{"kind":"upstream","message":"LLM 502","retryable":true}}
        """
        let buffer = "event: error\ndata: \(payload)\n\n"
        let events = parser.consume(buffer: buffer)
        XCTAssertEqual(events.count, 1)
        if case .error(let err) = events[0] {
            XCTAssertTrue(err.retryable)
        } else { XCTFail("expected .error") }
    }

    /// v1.2.0 (HH) P6 — locks the timeout values so a future edit can't
    /// silently regress them. `timeoutIntervalForRequest` (per-chunk gap
    /// upper bound) stays at 120s, aligned with Nginx `proxy_read_timeout
    /// 120s`; `timeoutIntervalForResource` (whole-stream upper bound) is
    /// widened 600s → 3600s so a slow relay writing a full chapter at
    /// 1-2 字/秒 (which can run >30 minutes) doesn't get cut off mid-stream,
    /// while still keeping a finite ceiling against a truly-hung connection.
    func test_makeDefaultSession_hasP6TimeoutValues() {
        let session = SSEClient.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 3600)
    }
}
