import Foundation

/// Strongly-typed SSE event emitted by the backend writer agent.
public enum SSEEvent: Equatable, Sendable {
    case started(chapterId: String)
    case token(text: String)
    case progress(chars: Int)
    case done(chapter: Chapter)
    case error(AppError)
    /// Catch-all for unknown event types so the stream can keep flowing.
    case other(name: String, data: String)
}

/// Stateful SSE wire-format parser (independent of any transport).
/// Buffers bytes by line; on a blank line, dispatches the accumulated event.
public final class SSEParser {
    private var pendingEvent: String?
    private var pendingData: [String] = []

    public init() {}

    /// Feed a full text line (without trailing newline) and get back a finished `SSEEvent`
    /// when the line terminates a message (i.e. line is empty).
    /// Returns `nil` until enough lines have accumulated.
    public func consume(line: String) -> SSEEvent? {
        // Comment / keepalive line.
        if line.hasPrefix(":") { return nil }

        if line.isEmpty {
            // Blank line == dispatch.
            let event = pendingEvent ?? "message"
            let data = pendingData.joined(separator: "\n")
            pendingEvent = nil
            pendingData = []
            guard !data.isEmpty else { return nil }
            return decode(eventName: event, data: data)
        }

        if let colonIdx = line.firstIndex(of: ":") {
            let field = String(line[..<colonIdx])
            var rest = line[line.index(after: colonIdx)...]
            if rest.first == " " { rest = rest.dropFirst() }
            let value = String(rest)
            switch field {
            case "event": pendingEvent = value
            case "data": pendingData.append(value)
            default: break // ignore id:, retry:
            }
        }
        return nil
    }

    /// Convenience: split a buffer that may contain multiple lines.
    public func consume(buffer: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        // SSE allows \n, \r\n, or \r separators. Normalize.
        let normalized = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                               .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let e = consume(line: String(line)) {
                events.append(e)
            }
        }
        return events
    }

    private func decode(eventName: String, data: String) -> SSEEvent {
        let decoder = CodecFactory.makeDecoder()
        guard let jsonData = data.data(using: .utf8) else {
            return .other(name: eventName, data: data)
        }
        switch eventName {
        case "started":
            struct P: Decodable { let chapter_id: String }
            if let p = try? decoder.decode(P.self, from: jsonData) {
                return .started(chapterId: p.chapter_id)
            }
        case "token":
            struct P: Decodable { let text: String }
            if let p = try? decoder.decode(P.self, from: jsonData) {
                return .token(text: p.text)
            }
        case "progress":
            struct P: Decodable { let chars: Int }
            if let p = try? decoder.decode(P.self, from: jsonData) {
                return .progress(chars: p.chars)
            }
        case "done":
            struct P: Decodable { let chapter: Chapter }
            if let p = try? decoder.decode(P.self, from: jsonData) {
                return .done(chapter: p.chapter)
            }
        case "error":
            if let _ = try? decoder.decode(BackendErrorEnvelope.self, from: jsonData) {
                return .error(ErrorMapping.map(status: 500, body: jsonData))
            }
            return .error(.upstream(data, retryable: false))
        default:
            break
        }
        return .other(name: eventName, data: data)
    }
}

/// Streaming client that opens an SSE connection and yields `SSEEvent`s.
public final class SSEClient: @unchecked Sendable {
    /// Build a URLSession tuned for SSE long-lived writes against the cloud backend.
    /// v0.8 Phase U-2 (§5.U.2):
    ///   - `timeoutIntervalForRequest = 120`  — upper bound on gap between chunks / first byte.
    ///     公网长链路 + Nginx `proxy_read_timeout 120s` 对齐(§5.S.3)。
    ///   - `timeoutIntervalForResource = 600` — upper bound on total stream duration.
    ///     Writer 一章通常 1-3 分钟,留 10 分钟余量防 outlier 章节。
    /// 注：SSE 弱网断流时,URLSession 不会自动重试(会丢已收 token);客户端处理是
    /// "进入 .failed(upstream, retryable: true) 状态,用户决定重新生成",见
    /// `ChapterEditorStore.startWriting` / `refreshAfterIncompleteStream`(§5.U.5)。
    public static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? SSEClient.makeDefaultSession()
    }

    private let session: URLSession

    /// Open a POST SSE stream and return an `AsyncThrowingStream<SSEEvent, Error>`.
    /// Callers should `for try await` over it; cancelling the consuming task aborts.
    public func stream(request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Pull the whole body for error mapping.
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        continuation.finish(throwing: ErrorMapping.map(status: http.statusCode, body: data))
                        return
                    }
                    let parser = SSEParser()
                    var buffer: [UInt8] = []
                    for try await byte in bytes {
                        if Task.isCancelled {
                            continuation.finish(throwing: AppError.cancelled)
                            return
                        }
                        if byte == 0x0A { // \n
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            if let event = parser.consume(line: line) {
                                continuation.yield(event)
                                if case .done = event { continuation.finish(); return }
                                if case .error(let e) = event {
                                    continuation.finish(throwing: e); return
                                }
                            }
                        } else if byte == 0x0D {
                            // ignore CR; LF will trigger dispatch
                        } else {
                            buffer.append(byte)
                        }
                    }
                    // Stream ended without an explicit `done` — finish gracefully.
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AppError.cancelled)
                } catch let e as AppError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AppError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
