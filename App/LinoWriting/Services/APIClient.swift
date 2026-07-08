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
    // v1.3.0 (II) P2 — "导入人物卡" LLM parse: POST /books/{id}/characters/parse.
    func parseCharacters(bookId: String, rawText: String) async throws -> [Character]
    func listTimeline(characterId: String, limit: Int, before: Date?) async throws -> [TimelineEvent]
    func updateTimelineEvent(id: String, eventText: String?, eventType: TimelineEventType?) async throws -> TimelineEvent
    func deleteTimelineEvent(id: String) async throws

    // Chapters
    func listChapters(bookId: String) async throws -> [ChapterSummary]
    func createChapter(bookId: String, _ req: ChapterCreateRequest) async throws -> Chapter
    func getChapter(id: String) async throws -> Chapter
    func patchChapter(id: String, _ req: ChapterPatchRequest) async throws -> Chapter
    func deleteChapter(id: String) async throws

    // Flow actions
    func expand(chapterId: String, force: Bool) async throws -> Chapter
    func writeStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error>
    // v1.3.2 (LL) P1 — writing-as-a-job: reattach to an in-flight (or
    // just-finished) write; explicitly cancel one.
    func reattachWriteStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error>
    func cancelWrite(chapterId: String) async throws -> Chapter
    // v1.4.0 (MM) P4 — standalone revision of an existing draft_ready draft:
    // `POST /chapters/{id}/revise` (SSE, same shape as `writeStream`).
    // Disconnect/reattach reuses `reattachWriteStream` (job-agnostic).
    func reviseStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error>
    func finalize(chapterId: String) async throws -> FinalizeResult
    func reopen(chapterId: String) async throws -> Chapter
    func importChapter(id: String, payload: ChapterImportRequest) async throws -> ChapterImportResponse
    func extractChapter(id: String) async throws -> ChapterImportResponse
    func adminResetChapter(id: String, targetStatus: ChapterStatus) async throws -> Chapter

    // Admin
    func listAgentLogs(
        chapterId: String?,
        agentName: String?,
        limit: Int,
        before: Date?
    ) async throws -> [AgentLog]

    // Agent personas (v1.0.0 EE §5.4) — DB-stored, App-editable persona layer.
    func listAgentPersonas() async throws -> [AgentPersona]
    func patchAgentPersona(agentRole: AgentRole, systemPrompt: String) async throws -> AgentPersona
    func resetAgentPersona(agentRole: AgentRole) async throws -> AgentPersona

    // Provider keys (§5.E.4)
    func listProviderKeys() async throws -> [ProviderKey]
    func createProviderKey(_ payload: ProviderKeyCreate) async throws -> ProviderKey
    func updateProviderKey(id: String, payload: ProviderKeyUpdate) async throws -> ProviderKey
    func deleteProviderKey(id: String) async throws
    func getActiveProviderKey() async throws -> ActiveProviderKeySummary
    func setActiveProviderKey(id: String) async throws -> ActiveProviderKeySummary

    // Per-Agent active key (§5.M / M-1)
    func getActiveAgentKey(agentRole: AgentRole) async throws -> ActiveAgentKeyRead
    func setActiveAgentKey(agentRole: AgentRole, providerKeyId: String?) async throws -> ActiveAgentKeyRead

    // Export (§5.F)
    func exportBook(id: String, format: ExportFormat, includeDrafts: Bool) async throws -> (data: Data, suggestedFilename: String)
    func exportChapter(id: String, format: ExportFormat) async throws -> (data: Data, suggestedFilename: String)
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

    public init(
        session: URLSession = .shared,
        config: @escaping ConfigProvider
    ) {
        self.session = session
        // v0.8 Phase U-2 (§5.U.2): SSE 走自己的 timeout-tuned URLSession
        // (timeoutIntervalForRequest = 120s / forResource = 600s),不复用
        // 常规 REST 用的 short-timeout `.shared` session。
        // Tests 可通过 `SSEClient(session:)` 直接注入 mock session 旁路。
        self.sseClient = SSEClient()
        self.configProvider = config
    }

    /// Convenience init for tests/previews with a fixed config.
    public convenience init(session: URLSession = .shared, baseURL: URL, token: String) {
        self.init(session: session, config: { Config(baseURL: baseURL, token: token) })
    }

    // MARK: Request building

    /// v1.3.1 (KK) P3 — slow endpoints (extract/expand/finalize/import/parse,
    /// all backed by an LLM round-trip that can legitimately run past a
    /// minute with a reasoning model) get a longer per-request timeout than
    /// the default. `.shared`'s session-level timeout (60s) and the SSE
    /// tuned session (120s/3600s, `SSEClient`) are both untouched — this is
    /// strictly a per-`URLRequest` override for the handful of REST callers
    /// listed below.
    static let slowEndpointTimeout: TimeInterval = 300

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json; charset=utf-8",
        accept: String = "application/json; charset=utf-8",
        timeout: TimeInterval? = nil
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
        if let timeout {
            req.timeoutInterval = timeout
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

    // v1.3.0 (II) P2 — POST /books/{id}/characters/parse. Backend returns
    // `{"items": [CharacterRead, ...]}`, same envelope shape as listCharacters.
    // v1.3.1 (KK) P3: LLM-backed parse, gets the slow-endpoint timeout.
    public func parseCharacters(bookId: String, rawText: String) async throws -> [Character] {
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/books/\(bookId)/characters/parse",
                                  body: body(CharacterParseRequest(rawText: rawText)),
                                  timeout: Self.slowEndpointTimeout)
        let resp: ListResponse<Character> = try await send(req, as: ListResponse<Character>.self)
        return resp.items
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

    /// `PATCH /api/v1/timeline_events/{id}` — see PROJECT_PLAN §5.C.
    ///
    /// At least one of `eventText` / `eventType` must be non-nil; passing both
    /// nil produces a 422 from the backend (deliberate — empty PATCH would be
    /// a no-op that still stamps `edited_at`, which would lie about whether
    /// the user actually changed anything).
    public func updateTimelineEvent(
        id: String,
        eventText: String?,
        eventType: TimelineEventType?
    ) async throws -> TimelineEvent {
        let payload = TimelineEventPatchRequest(eventText: eventText, eventType: eventType)
        let req = try makeRequest(method: "PATCH",
                                  path: "/api/v1/timeline_events/\(id)",
                                  body: body(payload))
        return try await send(req, as: TimelineEvent.self)
    }

    public func deleteTimelineEvent(id: String) async throws {
        let req = try makeRequest(method: "DELETE", path: "/api/v1/timeline_events/\(id)")
        try await sendNoBody(req)
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
        // v1.3.1 (KK) P3: expander is an LLM round-trip — slow-endpoint timeout.
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/chapters/\(chapterId)/expand",
                                  query: q,
                                  body: "{}".data(using: .utf8),
                                  timeout: Self.slowEndpointTimeout)
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

    /// v1.3.2 (LL) P1 — `GET /chapters/{id}/write/stream`. Reattach SSE. Reuses
    /// the SSE-tuned session; a client disconnect here only tears down the
    /// subscription (the backend job keeps running).
    public func reattachWriteStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(
                method: "GET",
                path: "/api/v1/chapters/\(chapterId)/write/stream",
                accept: "text/event-stream"
            )
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return sseClient.stream(request: request)
    }

    /// v1.4.0 (MM) P4 — `POST /chapters/{id}/revise`. Standalone two-pass
    /// compression of an existing `draft_ready` draft, job-ified exactly
    /// like `writeStream` (SSE `started` → `revising` → `done{chapter,
    /// revision}`); a disconnect only tears down this subscription, and
    /// reconnection reuses `reattachWriteStream` (job-agnostic by design).
    public func reviseStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(
                method: "POST",
                path: "/api/v1/chapters/\(chapterId)/revise",
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

    /// v1.3.2 (LL) P1 — `POST /chapters/{id}/write/cancel`. The only real "停止
    /// 生成": sets the backend cancel signal and returns the (possibly still
    /// `writing`) chapter row after a bounded wait.
    public func cancelWrite(chapterId: String) async throws -> Chapter {
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/chapters/\(chapterId)/write/cancel",
            body: "{}".data(using: .utf8)
        )
        return try await send(req, as: Chapter.self)
    }

    public func finalize(chapterId: String) async throws -> FinalizeResult {
        // v1.3.1 (KK) P3: finalize runs the Extractor (archivist) — LLM
        // round-trip, slow-endpoint timeout.
        let req = try makeRequest(method: "POST",
                                  path: "/api/v1/chapters/\(chapterId)/finalize",
                                  body: "{}".data(using: .utf8),
                                  timeout: Self.slowEndpointTimeout)
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
        // v1.3.1 (KK) P3/P4: single-chapter import now defaults to
        // `run_extractor=true` (P4), making this an LLM-backed round-trip
        // same as extract/expand/finalize — slow-endpoint timeout so a
        // thinking-model extraction isn't cut off at 60s.
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/chapters/\(id)/import",
            body: body(payload),
            timeout: Self.slowEndpointTimeout
        )
        return try await send(req, as: ChapterImportResponse.self)
    }

    /// `POST /api/v1/chapters/{id}/extract` — see PROJECT_PLAN v0.9.3 §5.DI.2.
    ///
    /// Manually re-runs the Extractor against an already-`finalized` chapter
    /// that has `draft_text`. The backend clears this chapter's old timeline
    /// events first (so repeated extracts don't pile up duplicate events),
    /// then writes character live_fields + new timeline events. The chapter's
    /// status / draft_text are left untouched.
    ///
    /// No request body (mirrors `finalize` / `reopen`). The response reuses
    /// the import/finalize envelope `{ chapter, updated_character_ids,
    /// added_event_ids }`, so callers fan out the dependent-store refreshes
    /// identically to `importChapter` / `finalize`.
    ///
    /// 409 is expected when the chapter isn't `finalized`, or when it's
    /// `finalized` but has empty `draft_text` (backend `no_draft_to_extract`).
    /// The message is preserved by `ErrorMapping` for the toolbar to surface.
    public func extractChapter(id: String) async throws -> ChapterImportResponse {
        // v1.3.1 (KK) P3: manual re-extract is an LLM round-trip — slow-endpoint timeout.
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/chapters/\(id)/extract",
            body: "{}".data(using: .utf8),
            timeout: Self.slowEndpointTimeout
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

    public func listAgentLogs(
        chapterId: String?,
        agentName: String?,
        limit: Int,
        before: Date?
    ) async throws -> [AgentLog] {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let chapterId { q.append(URLQueryItem(name: "chapter_id", value: chapterId)) }
        if let agentName { q.append(URLQueryItem(name: "agent_name", value: agentName)) }
        if let before {
            // v0.7 §5.D — match the `before` formatting used by listTimeline so
            // the backend's `datetime` parser accepts it without surprises
            // (`+00:00` offset + fractional seconds, ISO-8601).
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            q.append(URLQueryItem(name: "before", value: f.string(from: before)))
        }
        let req = try makeRequest(method: "GET", path: "/api/v1/admin/logs", query: q)
        let resp: ListResponse<AgentLog> = try await send(req, as: ListResponse<AgentLog>.self)
        return resp.items
    }

    // MARK: - Agent personas (v1.0.0 EE §5.4)

    /// `GET /api/v1/agent-personas` — three rows (expander/writer/extractor),
    /// each `{ agent_role, system_prompt, is_default, updated_at }`.
    public func listAgentPersonas() async throws -> [AgentPersona] {
        let req = try makeRequest(method: "GET", path: "/api/v1/agent-personas")
        let env: AgentPersonaListEnvelope = try await send(req, as: AgentPersonaListEnvelope.self)
        return env.personas
    }

    /// `PATCH /api/v1/agent-personas/{role}` — overwrite `system_prompt`,
    /// flips `is_default` → false. An empty / whitespace-only prompt is a 422
    /// (backend validator); the editor guards against that before calling.
    public func patchAgentPersona(agentRole: AgentRole, systemPrompt: String) async throws -> AgentPersona {
        let req = try makeRequest(
            method: "PATCH",
            path: "/api/v1/agent-personas/\(agentRole.rawValue)",
            body: body(AgentPersonaUpdateRequest(systemPrompt: systemPrompt))
        )
        let env: AgentPersonaEnvelope = try await send(req, as: AgentPersonaEnvelope.self)
        return env.persona
    }

    /// `POST /api/v1/agent-personas/{role}/reset` — restore the seed default
    /// (`DEFAULT_PERSONAS[role]`) and flip `is_default` → true. No body
    /// (mirrors other action endpoints).
    public func resetAgentPersona(agentRole: AgentRole) async throws -> AgentPersona {
        let req = try makeRequest(
            method: "POST",
            path: "/api/v1/agent-personas/\(agentRole.rawValue)/reset",
            body: "{}".data(using: .utf8)
        )
        let env: AgentPersonaEnvelope = try await send(req, as: AgentPersonaEnvelope.self)
        return env.persona
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

    // MARK: - Per-Agent active key (§5.M / M-1)

    /// `GET /api/v1/settings/active_key/{agent_role}` — fetch a single agent's
    /// active key. `agent_role` 走路径段（writer/extractor/expander）。
    public func getActiveAgentKey(agentRole: AgentRole) async throws -> ActiveAgentKeyRead {
        let req = try makeRequest(
            method: "GET",
            path: "/api/v1/settings/active_key/\(agentRole.rawValue)"
        )
        return try await send(req, as: ActiveAgentKeyRead.self)
    }

    /// `PUT /api/v1/settings/active_key/{agent_role}` — set or clear the
    /// active key for a single agent. `providerKeyId == nil` 表示清回通用
    /// fallback（body 显式 `{"provider_key_id": null}`）。
    ///
    /// 后端在 key.agent_role 与 slot 不匹配时返 409；ErrorMapping 已统一把
    /// conflict 映射成 `AppError.conflict`，store 层会发布到 ErrorBus。
    public func setActiveAgentKey(
        agentRole: AgentRole,
        providerKeyId: String?
    ) async throws -> ActiveAgentKeyRead {
        let payload = ActiveAgentKeyUpdate(providerKeyId: providerKeyId)
        let req = try makeRequest(
            method: "PUT",
            path: "/api/v1/settings/active_key/\(agentRole.rawValue)",
            body: body(payload)
        )
        return try await send(req, as: ActiveAgentKeyRead.self)
    }

    // MARK: - Export (§5.F)

    /// `GET /api/v1/books/{id}/export?format=…&include_drafts=…` —
    /// returns the raw body + the filename suggested by the backend
    /// via ``Content-Disposition``.
    ///
    /// The body is *not* JSON — it's plain Markdown / TXT. ``FileSaver``
    /// takes the tuple and writes it to a user-picked location.
    public func exportBook(
        id: String,
        format: ExportFormat,
        includeDrafts: Bool
    ) async throws -> (data: Data, suggestedFilename: String) {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "format", value: format.rawValue),
            URLQueryItem(name: "include_drafts", value: includeDrafts ? "true" : "false")
        ]
        let req = try makeRequest(
            method: "GET",
            path: "/api/v1/books/\(id)/export",
            query: q,
            accept: format.contentType
        )
        let (data, resp) = try await performRaw(req)
        let filename = Self.parseSuggestedFilename(from: resp)
            ?? "untitled.\(format.fileExtension)"
        return (data, filename)
    }

    /// `GET /api/v1/chapters/{id}/export?format=…` — single-chapter
    /// variant. Same response handling as ``exportBook``.
    public func exportChapter(
        id: String,
        format: ExportFormat
    ) async throws -> (data: Data, suggestedFilename: String) {
        let q: [URLQueryItem] = [URLQueryItem(name: "format", value: format.rawValue)]
        let req = try makeRequest(
            method: "GET",
            path: "/api/v1/chapters/\(id)/export",
            query: q,
            accept: format.contentType
        )
        let (data, resp) = try await performRaw(req)
        let filename = Self.parseSuggestedFilename(from: resp)
            ?? "chapter.\(format.fileExtension)"
        return (data, filename)
    }

    /// Parse the suggested filename out of an HTTP ``Content-Disposition``
    /// header. Prefers RFC 5987 ``filename*=UTF-8''…`` (the encoded form
    /// the backend emits in ``build_content_disposition``) because that
    /// preserves Chinese; falls back to the plain ``filename="…"`` if
    /// only that variant is present.
    ///
    /// Returns ``nil`` when neither form is recognisable so the caller
    /// can fall back to a sensible default (e.g. ``untitled.md``).
    static func parseSuggestedFilename(from response: HTTPURLResponse) -> String? {
        // Field name lookup is case-insensitive per HTTP, but
        // `allHeaderFields` on `HTTPURLResponse` uses canonical casing
        // on Darwin so the exact key works in practice. We probe both
        // common spellings just to be safe with mocks/tests.
        let raw = (response.value(forHTTPHeaderField: "Content-Disposition")
                   ?? response.value(forHTTPHeaderField: "content-disposition"))
        guard let header = raw else { return nil }

        // Try ``filename*=UTF-8''<encoded>`` first.
        if let encoded = header.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let tail = header[encoded.upperBound...]
            // The encoded value runs until the next ``;`` or end-of-line.
            let endIdx = tail.firstIndex(of: ";") ?? tail.endIndex
            let percent = String(tail[..<endIdx]).trimmingCharacters(in: .whitespaces)
            if let decoded = percent.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }
        // Fallback: ``filename="<value>"`` (ASCII; only useful when the
        // backend or a proxy stripped the encoded form).
        if let plain = header.range(of: "filename=", options: .caseInsensitive) {
            let tail = header[plain.upperBound...]
            // Strip surrounding quotes if present.
            var value = String(tail.prefix { $0 != ";" })
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// Marker type for endpoints that return 204 No Content.
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
