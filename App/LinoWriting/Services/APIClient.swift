import Foundation

/// Protocol-typed network surface so stores can be tested against a mock.
public protocol APIClientProtocol: Sendable {
    // Bookshelf
    func listBooks() async throws -> [Book]
    func createBook(_ req: BookCreateRequest) async throws -> Book
    func getBook(id: String) async throws -> Book
    func patchBook(id: String, _ req: BookPatchRequest) async throws -> Book
    func deleteBook(id: String) async throws
    func touchBook(id: String) async throws

    // Characters
    func listCharacters(bookId: String) async throws -> [Character]
    func createCharacter(bookId: String, _ req: CharacterCreateRequest) async throws -> Character
    func getCharacter(id: String) async throws -> Character
    func patchCharacter(id: String, _ req: CharacterPatchRequest) async throws -> Character
    func deleteCharacter(id: String) async throws
    func listTimeline(characterId: String, limit: Int, before: Date?) async throws -> [TimelineEvent]

    // Chapters
    func listChapters(bookId: String) async throws -> [ChapterSummary]
    func createChapter(bookId: String, _ req: ChapterCreateRequest) async throws -> Chapter
    func getChapter(id: String) async throws -> Chapter
    func patchChapter(id: String, _ req: ChapterPatchRequest) async throws -> Chapter
    func deleteChapter(id: String) async throws

    // Flow actions
    func expand(chapterId: String, force: Bool) async throws -> Chapter
    func writeStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error>
    func finalize(chapterId: String) async throws -> FinalizeResult
    func reopen(chapterId: String) async throws -> Chapter
    func importChapter(id: String, payload: ChapterImportRequest) async throws -> ChapterImportResponse
    func adminResetChapter(id: String, targetStatus: ChapterStatus) async throws -> Chapter

    // Admin
    func listAgentLogs(chapterId: String?, limit: Int) async throws -> [AgentLog]

    // Provider keys (§5.E.4)
    func listProviderKeys() async throws -> [ProviderKey]
    func createProviderKey(_ payload: ProviderKeyCreate) async throws -> ProviderKey
    func updateProviderKey(id: String, payload: ProviderKeyUpdate) async throws -> ProviderKey
    func deleteProviderKey(id: String) async throws
    func getActiveProviderKey() async throws -> ActiveProviderKeySummary
    func setActiveProviderKey(id: String) async throws -> ActiveProviderKeySummary
}

/// Concrete URLSession-backed client.
public final class APIClient: APIClientProtocol, @unchecked Sendable {

    // MARK: Configuration

    public struct Config: Sendable {
        public var baseURL: URL
        public var token: String
        public init(baseURL: URL, token: String) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    public typealias ConfigProvider = @Sendable () -> Config?

    private let session: URLSession
    private let configProvider: ConfigProvider
    private let sseClient: SSEClient
    private let decoder = CodecFactory.makeDecoder()
    private let encoder = CodecFactory.makeEncoder()

    public init(session: URLSession = .shared, config: @escaping ConfigProvider) {
        self.session = session
        self.sseClient = SSEClient(session: session)
        self.configProvider = config
    }

    /// Convenience init for tests/previews with a fixed config.
    public convenience init(session: URLSession = .shared, baseURL: URL, token: String) {
        self.init(session: session, config: { Config(baseURL: baseURL, token: token) })
    }

    // MARK: Request building

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json; charset=utf-8",
        accept: String = "application/json; charset=utf-8"
    ) throws -> URLRequest {
        guard let cfg = configProvider() else {
            throw AppError.unauthorized("尚未配置后端地址或 Token")
        }
        var comps = URLComponents(url: cfg.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw AppError.transport("URL 构造失败") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    // MARK: Core round-trip

    /// Send the request and decode the JSON body as `T`. For empty 204 responses, pass `EmptyResponse.self`.
    private func send<T: Decodable>(_ req: URLRequest, as _: T.Type) async throws -> T {
        let (data, resp) = try await performRaw(req)
        if T.self == EmptyResponse.self {
            // For 204 endpoints, fabricate an empty value.
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AppError.decoding("响应解析失败：\(error.localizedDescription)；原始内容：\(String(data: data.prefix(512), encoding: .utf8) ?? "")")
        }
        _ = resp // silence unused
    }

    private func sendNoBody(_ req: URLRequest) async throws {
        _ = try await performRaw(req)
    }

    private func performRaw(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw AppError.cancelled
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ErrorMapping.map(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    // MARK: Encoding helper

    private func body<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw AppError.decoding("请求体编码失败：\(error.localizedDescription)") }
    }

    // MARK: - Books

    public func listBooks() async throws -> [Book] {
        let req = try makeRequest(method: "GET", path: "/api/v1/books")
        let resp: ListResponse<Book> = try await send(req, as: ListResponse<Book>.self)
        return resp.items
    }

    public func createBook(_ payload: BookCreateRequest) async throws -> Book {
        let req = try makeRequest(method: "POST", path: "/api/v1/books", body: body(payload))
        return try await send(req, as: Book.self)
    }

    public func getBook(id: String) async throws -> Book {
        let req = try makeRequest(method: "GET", path: "/api/v1/books/\(id)")
        return try await send(req, as: Book.self)
    }

    public func patchBook(id: String, _ payload: BookPatchRequest) async throws -> Book {
        let req = try makeRequest(method: "PATCH", path: "/api/v1/books/\(id)", body: body(payload))
        return try await send(req, as: Book.self)
    }

    public func deleteBook(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "/api/v1/books/\(id)")
        try await sendNoBody(req)
    }

    public func touchBook(id: String) async throws {
        let req = try makeRequest(method: "POST", path: "/api/v1/books/\(id)/touch")
        try await sendNoBody(req)
    }

    // MARK: - Characters

    public func listCharacters(bookId: String) async throws -> [Character] {
        let req = try makeRequest(method: "GET", path: "/api/v1/books/\(bookId)/characters")
        let resp: ListResponse<Character> = try await send(req, as: ListResponse<Character>.self)
        return resp.items
    }

    public func createCharacter(bookId: String, _ payload: CharacterCreateRequest) async throws -> Character {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/books/\(bookId)/characters",
                                  body: body(payload))
        return try await send(req, as: Character.self)
    }

    public func getCharacter(id: String) async throws -> Character {
        let req = try makeRequest(method: "GET", path: "/api/v1/characters/\(id)")
        return try await send(req, as: Character.self)
    }

    public func patchCharacter(id: String, _ payload: CharacterPatchRequest) async throws -> Character {
        let req = try makeRequest(method: "PATCH",
                                  path: "/api/v1/characters/\(id)",
                                  body: body(payload))
        return try await send(req, as: Character.self)
    }

    public func deleteCharacter(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "/api/v1/characters/\(id)")
        try await sendNoBody(req)
    }

    public func listTimeline(characterId: String, limit: Int, before: Date?) async throws -> [TimelineEvent] {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            q.append(URLQueryItem(name: "before", value: f.string(from: before)))
        }
        let req = try makeRequest(method: "GET",
                                  path: "/api/v1/characters/\(characterId)/timeline",
                                  query: q)
        let resp: ListResponse<TimelineEvent> = try await send(req, as: ListResponse<TimelineEvent>.self)
        return resp.items
    }

    // MARK: - Chapters

    public func listChapters(bookId: String) async throws -> [ChapterSummary] {
        let req = try makeRequest(method: "GET", path: "/api/v1/books/\(bookId)/chapters")
        let resp: ListResponse<ChapterSummary> = try await send(req, as: ListResponse<ChapterSummary>.self)
        return resp.items
    }

    public func createChapter(bookId: String, _ payload: ChapterCreateRequest) async throws -> Chapter {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/books/\(bookId)/chapters",
                                  body: body(payload))
        return try await send(req, as: Chapter.self)
    }

    public func getChapter(id: String) async throws -> Chapter {
        let req = try makeRequest(method: "GET", path: "/api/v1/chapters/\(id)")
        return try await send(req, as: Chapter.self)
    }

    public func patchChapter(id: String, _ payload: ChapterPatchRequest) async throws -> Chapter {
        let req = try makeRequest(method: "PATCH",
                                  path: "/api/v1/chapters/\(id)",
                                  body: body(payload))
        return try await send(req, as: Chapter.self)
    }

    public func deleteChapter(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "/api/v1/chapters/\(id)")
        try await sendNoBody(req)
    }

    // MARK: - Flow actions

    public func expand(chapterId: String, force: Bool = false) async throws -> Chapter {
        let q = force ? [URLQueryItem(name: "force", value: "true")] : []
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/chapters/\(chapterId)/expand",
                                  query: q,
                                  body: "{}".data(using: .utf8))
        return try await send(req, as: Chapter.self)
    }

    public func writeStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(
                method: "POST",
                path: "/api/v1/chapters/\(chapterId)/write",
                body: "{}".data(using: .utf8),
                accept: "text/event-stream"
            )
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return sseClient.stream(request: request)
    }

    public func finalize(chapterId: String) async throws -> FinalizeResult {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/chapters/\(chapterId)/finalize",
                                  body: "{}".data(using: .utf8))
        return try await send(req, as: FinalizeResult.self)
    }

    public func reopen(chapterId: String) async throws -> Chapter {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/chapters/\(chapterId)/reopen",
                                  body: "{}".data(using: .utf8))
        return try await send(req, as: Chapter.self)
    }

    /// `POST /api/v1/chapters/{id}/import` — see PROJECT_PLAN §5.A.4.
    ///
    /// 409 is the expected status when the backend's status white-list rejects
    /// the chapter (current state ∉ {draft, prompt_ready, draft_ready}). The
    /// error message from the body is preserved by `ErrorMapping` so the
    /// import sheet can surface it via `ErrorBus` without translating.
    public func importChapter(id: String, payload: ChapterImportRequest) async throws -> ChapterImportResponse {
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/chapters/\(id)/import",
            body: body(payload)
        )
        return try await send(req, as: ChapterImportResponse.self)
    }

    /// `POST /api/v1/chapters/{id}/admin_reset` — see PROJECT_PLAN §5.P.1 E.
    ///
    /// Force-resets a stuck chapter to a re-editable state. The backend
    /// accepts any current status and rewrites it to `target_status` while
    /// preserving `draft_text` / `structured_prompt`. The endpoint is
    /// idempotent — calling it twice with the same target is a no-op on
    /// the second call (no extra audit log row).
    public func adminResetChapter(id: String, targetStatus: ChapterStatus) async throws -> Chapter {
        let payload = ChapterAdminResetRequest(targetStatus: targetStatus)
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/chapters/\(id)/admin_reset",
            body: body(payload)
        )
        return try await send(req, as: Chapter.self)
    }

    // MARK: - Admin

    public func listAgentLogs(chapterId: String?, limit: Int) async throws -> [AgentLog] {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let chapterId { q.append(URLQueryItem(name: "chapter_id", value: chapterId)) }
        let req = try makeRequest(method: "GET", path: "/api/v1/admin/logs", query: q)
        let resp: ListResponse<AgentLog> = try await send(req, as: ListResponse<AgentLog>.self)
        return resp.items
    }

    // MARK: - Provider Keys (§5.E.4)

    public func listProviderKeys() async throws -> [ProviderKey] {
        let req = try makeRequest(method: "GET", path: "/api/v1/provider_keys")
        let resp: ListResponse<ProviderKey> = try await send(req, as: ListResponse<ProviderKey>.self)
        return resp.items
    }

    public func createProviderKey(_ payload: ProviderKeyCreate) async throws -> ProviderKey {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/provider_keys",
                                  body: body(payload))
        return try await send(req, as: ProviderKey.self)
    }

    public func updateProviderKey(id: String, payload: ProviderKeyUpdate) async throws -> ProviderKey {
        let req = try makeRequest(method: "PATCH",
                                  path: "/api/v1/provider_keys/\(id)",
                                  body: body(payload))
        return try await send(req, as: ProviderKey.self)
    }

    public func deleteProviderKey(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "/api/v1/provider_keys/\(id)")
        try await sendNoBody(req)
    }

    public func getActiveProviderKey() async throws -> ActiveProviderKeySummary {
        let req = try makeRequest(method: "GET", path: "/api/v1/settings/active_provider_key")
        return try await send(req, as: ActiveProviderKeySummary.self)
    }

    public func setActiveProviderKey(id: String) async throws -> ActiveProviderKeySummary {
        let payload = ActiveProviderKeyUpdate(providerKeyId: id)
        let req = try makeRequest(method: "PUT",
                                  path: "/api/v1/settings/active_provider_key",
                                  body: body(payload))
        return try await send(req, as: ActiveProviderKeySummary.self)
    }
}

/// Marker type for endpoints that return 204 No Content.
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
