import Foundation
@testable import LinoWriting

/// Hand-rolled mock that stores in-memory state and lets tests assert on calls.
public final class MockAPIClient: APIClientProtocol, @unchecked Sendable {

    public var books: [Book] = []
    public var characters: [Character] = []
    public var chapters: [Chapter] = []
    public var timelineEvents: [TimelineEvent] = []
    public var agentLogs: [AgentLog] = []
    public var providerKeys: [ProviderKey] = []
    public var activeProviderKeyId: String?
    /// §5.M / M-2: per-agent active slots(writer/extractor/expander)。
    /// nil 表示该 slot 未绑(fallback 走通用 active)。三个 key 总是 present,
    /// 模拟后端 `GET /settings/active_key/{role}` 永远不会返 404 的行为。
    public var activeAgentKeyIds: [AgentRole: String?] = [
        .writer: nil,
        .extractor: nil,
        .expander: nil
    ]

    /// v1.0.0 EE §5.4: in-memory persona rows keyed by role. Seeded lazily on
    /// first access so a test that doesn't touch personas pays nothing, and so
    /// the three rows always come back in a stable role order (mirrors the
    /// backend's `GET /agent-personas` envelope).
    public var personas: [AgentRole: AgentPersona] = [:]
    /// Last `(role, systemPrompt)` passed to `patchAgentPersona`, for tests
    /// asserting the Swift-side encoding survived (mirrors other `last*` hooks).
    public var lastPersonaPatch: (role: AgentRole, systemPrompt: String)?

    public var calls: [String] = []

    // Pluggable behaviour for flow tests.
    public var onExpand: ((String, Bool) -> Chapter)?
    public var onWrite: ((String) -> [SSEEvent])?
    public var onFinalize: ((String) -> FinalizeResult)?
    public var onReopen: ((String) -> Chapter)?
    public var onImport: ((String, ChapterImportRequest) throws -> ChapterImportResponse)?
    public var onExtract: ((String) throws -> ChapterImportResponse)?
    public var onAdminReset: ((String, ChapterStatus) -> Chapter)?
    /// v1.3.0 (II) P2 — pluggable "导入人物卡" LLM-parse result. Defaults to
    /// nil (no characters parsed) when unset; tests set this to control the
    /// mocked parse outcome, or throw to simulate a 502.
    public var onParseCharacters: ((String, String) throws -> [Character])?

    /// v1.2.0 (HH) P5 — simulates a *real* transport-level disconnect mid
    /// stream: yields the given tokens as `.token` events, then the
    /// `AsyncThrowingStream` itself finishes with `throwing: error` (NOT an
    /// `.error` SSEEvent — that's the graceful "backend told us it failed"
    /// path already covered by `onWrite`). This is what `SSEClient.swift`
    /// actually does on a URLSession timeout/dropped connection: the
    /// `for try await` loop in `ChapterEditorStore.startWriting` throws
    /// rather than receiving one more event, which is exactly the case the
    /// P5 catch-branch fix (`refreshAfterIncompleteStream`) targets.
    public var onWriteThrowAfterTokens: (tokens: [String], error: Error)?

    /// v1.3.2 (LL) P2 — pluggable reattach (`GET /write/stream`) events. Set to
    /// script snapshot/token/done/error/stranded/no-active outcomes.
    public var onReattach: ((String) -> [SSEEvent])?
    /// v1.3.2 (LL) P2 — reattach stream that yields events then throws (a
    /// transient mid-tail disconnect), so the store's bounded-retry loop can be
    /// exercised.
    public var onReattachThrowAfterEvents: (events: [SSEEvent], error: Error)?
    /// v1.3.2 (LL) P2 — pluggable `POST /write/cancel` result. Defaults to
    /// flipping the chapter to draft_ready (conservative-save shape) when unset.
    public var onCancelWrite: ((String) throws -> Chapter)?

    /// Captures the last `importChapter` payload so tests can assert that the
    /// Swift-side encoding (e.g. `runExtractor` → `run_extractor`) survived.
    public var lastImportPayload: ChapterImportRequest?

    public var errorToThrow: AppError?

    public init() {}

    /// §5.M / M-2: ProviderKeysStore.reloadBoth 现在并发触发 5 个网络请求
    /// (list / 通用 active / writer / extractor / expander),如果不加锁,
    /// 三个并发 `getActiveAgentKey` 会一起 mutating `calls` 数组并踩到
    /// 其它状态读,Swift Concurrency 偶发崩测试进程("Restarting after
    /// unexpected exit")。统一把每个 API 方法包在 `lock.withLock` 里既
    /// 序列化 `calls.append`,也序列化 store mutation/lookup,与真实后端
    /// "单连接单事务" 的隐含语义一致。
    private let lock = NSLock()

    private func recordCall(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(name)
    }

    private func maybeThrow() throws {
        if let e = errorToThrow { throw e }
    }

    /// 对所有需要触碰可变 state 的方法包一层锁。`block` 仍能 `throw`。
    fileprivate func locked<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try block()
    }

    public func listBooks() async throws -> [Book] {
        recordCall("listBooks")
        try maybeThrow()
        return books
    }

    public func createBook(_ req: BookCreateRequest) async throws -> Book {
        recordCall("createBook")
        try maybeThrow()
        let book = Book(
            id: UUID().uuidString,
            title: req.title,
            coverColor: req.coverColor,
            createdAt: Date(),
            updatedAt: Date()
        )
        books.append(book)
        return book
    }

    public func getBook(id: String) async throws -> Book {
        recordCall("getBook")
        try maybeThrow()
        guard let book = books.first(where: { $0.id == id }) else { throw AppError.notFound("book") }
        return book
    }

    public func patchBook(id: String, _ req: BookPatchRequest) async throws -> Book {
        recordCall("patchBook")
        try maybeThrow()
        guard let idx = books.firstIndex(where: { $0.id == id }) else { throw AppError.notFound("book") }
        var book = books[idx]
        if let t = req.title { book.title = t }
        if let c = req.coverColor { book.coverColor = c }
        if let w = req.worldSetting { book.worldSetting = w }
        book.updatedAt = Date()
        books[idx] = book
        return book
    }

    public func deleteBook(id: String) async throws {
        recordCall("deleteBook")
        try maybeThrow()
        books.removeAll { $0.id == id }
    }

    public func touchBook(id: String) async throws {
        recordCall("touchBook")
        try maybeThrow()
        if let idx = books.firstIndex(where: { $0.id == id }) {
            books[idx].lastOpenedAt = Date()
        }
    }

    public func listCharacters(bookId: String) async throws -> [Character] {
        recordCall("listCharacters")
        try maybeThrow()
        return characters.filter { $0.bookId == bookId }
    }

    public func createCharacter(bookId: String, _ req: CharacterCreateRequest) async throws -> Character {
        recordCall("createCharacter")
        try maybeThrow()
        let c = Character(
            id: UUID().uuidString,
            bookId: bookId,
            name: req.name,
            role: req.role,
            frozenFields: req.frozenFields ?? [:],
            liveFields: req.liveFields ?? [:],
            createdAt: Date(),
            updatedAt: Date()
        )
        characters.append(c)
        return c
    }

    public func getCharacter(id: String) async throws -> Character {
        recordCall("getCharacter")
        try maybeThrow()
        guard let c = characters.first(where: { $0.id == id }) else { throw AppError.notFound("character") }
        return c
    }

    public func patchCharacter(id: String, _ req: CharacterPatchRequest) async throws -> Character {
        recordCall("patchCharacter")
        try maybeThrow()
        guard let idx = characters.firstIndex(where: { $0.id == id }) else { throw AppError.notFound("character") }
        var c = characters[idx]
        if let n = req.name { c.name = n }
        if let r = req.role { c.role = r }
        if let f = req.frozenFields { c.frozenFields = f }
        if let l = req.liveFields { c.liveFields = l }
        if let notes = req.authorNotes { c.authorNotes = notes }
        c.updatedAt = Date()
        characters[idx] = c
        return c
    }

    public func deleteCharacter(id: String) async throws {
        recordCall("deleteCharacter")
        try maybeThrow()
        characters.removeAll { $0.id == id }
        timelineEvents.removeAll { $0.characterId == id }
    }

    public func parseCharacters(bookId: String, rawText: String) async throws -> [Character] {
        recordCall("parseCharacters")
        try maybeThrow()
        let parsed = try onParseCharacters?(bookId, rawText) ?? []
        characters.append(contentsOf: parsed)
        return parsed
    }

    public func listTimeline(characterId: String, limit: Int, before: Date?) async throws -> [TimelineEvent] {
        recordCall("listTimeline")
        try maybeThrow()
        var events = timelineEvents.filter { $0.characterId == characterId }
        if let before { events = events.filter { $0.createdAt < before } }
        return Array(events.prefix(limit))
    }

    public func updateTimelineEvent(
        id: String,
        eventText: String?,
        eventType: TimelineEventType?
    ) async throws -> TimelineEvent {
        recordCall("updateTimelineEvent")
        try maybeThrow()
        guard let idx = timelineEvents.firstIndex(where: { $0.id == id }) else {
            throw AppError.notFound("timeline_event")
        }
        var e = timelineEvents[idx]
        if let t = eventText { e.eventText = t }
        if let k = eventType { e.eventType = k }
        e.editedAt = Date()
        timelineEvents[idx] = e
        return e
    }

    public func deleteTimelineEvent(id: String) async throws {
        recordCall("deleteTimelineEvent")
        try maybeThrow()
        timelineEvents.removeAll { $0.id == id }
    }

    public func listChapters(bookId: String) async throws -> [ChapterSummary] {
        recordCall("listChapters")
        try maybeThrow()
        return chapters.filter { $0.bookId == bookId }.map { $0.summaryShape }
    }

    public func createChapter(bookId: String, _ req: ChapterCreateRequest) async throws -> Chapter {
        recordCall("createChapter")
        try maybeThrow()
        let nextIndex = (chapters.filter { $0.bookId == bookId }.map { $0.index }.max() ?? 0) + 1
        let chapter = Chapter(
            id: UUID().uuidString,
            bookId: bookId,
            index: nextIndex,
            title: req.title,
            userPrompt: req.userPrompt,
            status: .draft,
            createdAt: Date(),
            updatedAt: Date()
        )
        chapters.append(chapter)
        return chapter
    }

    public func getChapter(id: String) async throws -> Chapter {
        recordCall("getChapter")
        try maybeThrow()
        guard let c = chapters.first(where: { $0.id == id }) else { throw AppError.notFound("chapter") }
        return c
    }

    public func patchChapter(id: String, _ req: ChapterPatchRequest) async throws -> Chapter {
        recordCall("patchChapter")
        try maybeThrow()
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else { throw AppError.notFound("chapter") }
        var c = chapters[idx]
        if let t = req.title { c.title = t }
        if let u = req.userPrompt { c.userPrompt = u }
        if let s = req.structuredPrompt { c.structuredPrompt = s }
        if let d = req.draftText { c.draftText = d }
        c.updatedAt = Date()
        chapters[idx] = c
        return c
    }

    public func deleteChapter(id: String) async throws {
        recordCall("deleteChapter")
        try maybeThrow()
        chapters.removeAll { $0.id == id }
    }

    // MARK: - Agent personas (v1.0.0 EE §5.4 mock)

    /// Seed text used by the mock so a reset can flip `system_prompt` back to a
    /// known string and tests can assert "restored to default". Not the real
    /// backend `DEFAULT_PERSONAS` (those live server-side); just a stable stub.
    private func defaultPersonaText(_ role: AgentRole) -> String {
        "[默认人格] \(role.rawValue)"
    }

    /// Lazily seed the three rows (is_default=true) on first access.
    private func ensurePersonasSeeded() {
        guard personas.isEmpty else { return }
        let now = Date()
        for role in [AgentRole.expander, .writer, .extractor] {
            personas[role] = AgentPersona(
                agentRole: role,
                systemPrompt: defaultPersonaText(role),
                isDefault: true,
                updatedAt: now
            )
        }
    }

    public func listAgentPersonas() async throws -> [AgentPersona] {
        recordCall("listAgentPersonas")
        return try locked {
            try maybeThrow()
            ensurePersonasSeeded()
            // Stable role order: expander, writer, extractor.
            return [AgentRole.expander, .writer, .extractor].compactMap { personas[$0] }
        }
    }

    public func patchAgentPersona(agentRole: AgentRole, systemPrompt: String) async throws -> AgentPersona {
        recordCall("patchAgentPersona")
        return try locked {
            lastPersonaPatch = (agentRole, systemPrompt)
            try maybeThrow()
            ensurePersonasSeeded()
            let updated = AgentPersona(
                agentRole: agentRole,
                systemPrompt: systemPrompt,
                isDefault: false,
                updatedAt: Date()
            )
            personas[agentRole] = updated
            return updated
        }
    }

    public func resetAgentPersona(agentRole: AgentRole) async throws -> AgentPersona {
        recordCall("resetAgentPersona")
        return try locked {
            try maybeThrow()
            ensurePersonasSeeded()
            let restored = AgentPersona(
                agentRole: agentRole,
                systemPrompt: defaultPersonaText(agentRole),
                isDefault: true,
                updatedAt: Date()
            )
            personas[agentRole] = restored
            return restored
        }
    }

    public func expand(chapterId: String, force: Bool) async throws -> Chapter {
        recordCall("expand")
        try maybeThrow()
        if let onExpand {
            let updated = onExpand(chapterId, force)
            if let idx = chapters.firstIndex(where: { $0.id == chapterId }) { chapters[idx] = updated }
            return updated
        }
        guard let idx = chapters.firstIndex(where: { $0.id == chapterId }) else { throw AppError.notFound("chapter") }
        var c = chapters[idx]
        c.structuredPrompt = StructuredPrompt(
            plotAnchors: ["事件 A"],
            charactersInvolved: []
        )
        c.status = .promptReady
        c.updatedAt = Date()
        chapters[idx] = c
        return c
    }

    public func writeStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        recordCall("writeStream")
        if let onWriteThrowAfterTokens {
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.started(chapterId: chapterId))
                    for token in onWriteThrowAfterTokens.tokens {
                        continuation.yield(.token(text: token))
                    }
                    continuation.finish(throwing: onWriteThrowAfterTokens.error)
                }
            }
        }
        let events: [SSEEvent]
        if let onWrite {
            events = onWrite(chapterId)
        } else {
            // Default: emit two tokens and a `done` with status=draft_ready.
            if let idx = chapters.firstIndex(where: { $0.id == chapterId }) {
                var c = chapters[idx]
                c.draftText = "Mock body."
                c.status = .draftReady
                c.updatedAt = Date()
                chapters[idx] = c
                events = [
                    .started(chapterId: chapterId),
                    .token(text: "Mock "),
                    .token(text: "body."),
                    .done(chapter: c, revision: nil)
                ]
            } else {
                events = [.error(.notFound("chapter"))]
            }
        }
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    if case .done = event { break }
                    // v1.3.2 (LL) P2 审后修复 #4: a terminal `.error` frame
                    // finishes the stream *gracefully* (mirrors the real
                    // SSEClient) — it's a definitive outcome the store handles
                    // via `applyWriteEvent(.error)`, not a transport throw.
                    if case .error = event { continuation.finish(); return }
                }
                continuation.finish()
            }
        }
    }

    public func reattachWriteStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        recordCall("reattachWriteStream")
        if let hook = onReattachThrowAfterEvents {
            return AsyncThrowingStream { continuation in
                Task {
                    for event in hook.events { continuation.yield(event) }
                    continuation.finish(throwing: hook.error)
                }
            }
        }
        let events: [SSEEvent]
        if let onReattach {
            events = onReattach(chapterId)
        } else if let idx = chapters.firstIndex(where: { $0.id == chapterId }) {
            // Default: replay a snapshot then complete with the current chapter.
            let c = chapters[idx]
            events = [
                .started(chapterId: chapterId),
                .snapshot(buffer: c.draftText ?? "", chars: (c.draftText ?? "").count),
                .done(chapter: c, revision: nil),
            ]
        } else {
            events = [.reattachNoActive]
        }
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    if case .done = event { break }
                    // 审后修复 #4 — graceful finish on terminal `.error` (see writeStream).
                    if case .error = event { continuation.finish(); return }
                }
                continuation.finish()
            }
        }
    }

    /// v1.4.0 (MM) P4 — pluggable standalone-revise (`POST /revise`) events.
    /// Script `.started`/`.revising`/`.done(chapter:revision:)`/`.error`
    /// sequences exactly like `onWrite`. Defaults to an in-range no-op revise
    /// (draft already within bounds) when unset.
    public var onRevise: ((String) -> [SSEEvent])?

    public func reviseStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        recordCall("reviseStream")
        let events: [SSEEvent]
        if let onRevise {
            events = onRevise(chapterId)
        } else if let idx = chapters.firstIndex(where: { $0.id == chapterId }) {
            let c = chapters[idx]
            events = [
                .started(chapterId: chapterId),
                .revising,
                .done(chapter: c, revision: "in_range"),
            ]
        } else {
            events = [.error(.notFound("chapter"))]
        }
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    if case .done = event { break }
                    // 审后修复 #4 — graceful finish on terminal `.error` (see writeStream).
                    if case .error = event { continuation.finish(); return }
                }
                continuation.finish()
            }
        }
    }

    /// v1.3.2 (LL) P2 审后修复 #2 — optional delay so a test can keep the cancel
    /// round-trip in flight while it switches chapters (cross-chapter guard test).
    public var cancelWriteDelayNanos: UInt64 = 0

    public func cancelWrite(chapterId: String) async throws -> Chapter {
        recordCall("cancelWrite")
        if cancelWriteDelayNanos > 0 { try? await Task.sleep(nanoseconds: cancelWriteDelayNanos) }
        try maybeThrow()
        if let onCancelWrite { return try onCancelWrite(chapterId) }
        guard let idx = chapters.firstIndex(where: { $0.id == chapterId }) else {
            throw AppError.notFound("chapter")
        }
        var c = chapters[idx]
        // Default conservative-save shape: land whatever draft exists as draft_ready.
        c.status = .draftReady
        c.updatedAt = Date()
        chapters[idx] = c
        return c
    }

    public func finalize(chapterId: String) async throws -> FinalizeResult {
        recordCall("finalize")
        try maybeThrow()
        if let onFinalize { return onFinalize(chapterId) }
        guard let idx = chapters.firstIndex(where: { $0.id == chapterId }) else { throw AppError.notFound("chapter") }
        var c = chapters[idx]
        c.summary = "Mock summary."
        c.status = .finalized
        c.updatedAt = Date()
        chapters[idx] = c
        return FinalizeResult(chapter: c, updatedCharacterIds: [], addedEventIds: [])
    }

    public func reopen(chapterId: String) async throws -> Chapter {
        recordCall("reopen")
        try maybeThrow()
        if let onReopen { return onReopen(chapterId) }
        guard let idx = chapters.firstIndex(where: { $0.id == chapterId }) else { throw AppError.notFound("chapter") }
        var c = chapters[idx]
        c.summary = nil
        c.status = .draftReady
        c.updatedAt = Date()
        chapters[idx] = c
        return c
    }

    public func importChapter(id: String, payload: ChapterImportRequest) async throws -> ChapterImportResponse {
        recordCall("importChapter")
        lastImportPayload = payload
        try maybeThrow()
        if let onImport { return try onImport(id, payload) }
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else {
            throw AppError.notFound("chapter")
        }
        var c = chapters[idx]
        c.draftText = payload.draftText
        if let t = payload.title { c.title = t }
        if let s = payload.summary { c.summary = s }
        c.source = .imported
        c.status = .finalized
        c.updatedAt = Date()
        chapters[idx] = c
        return ChapterImportResponse(
            chapter: c,
            updatedCharacterIds: [],
            addedEventIds: []
        )
    }

    public func extractChapter(id: String) async throws -> ChapterImportResponse {
        recordCall("extractChapter")
        try maybeThrow()
        if let onExtract { return try onExtract(id) }
        // Default: chapter must already be finalized with draft_text; leave
        // status / draft_text untouched and return an empty-ids envelope
        // (mirrors the backend's "extract doesn't change the chapter row").
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else {
            throw AppError.notFound("chapter")
        }
        let c = chapters[idx]
        return ChapterImportResponse(
            chapter: c,
            updatedCharacterIds: [],
            addedEventIds: []
        )
    }

    public func adminResetChapter(id: String, targetStatus: ChapterStatus) async throws -> Chapter {
        recordCall("adminResetChapter")
        try maybeThrow()
        if let onAdminReset { return onAdminReset(id, targetStatus) }
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else {
            throw AppError.notFound("chapter")
        }
        var c = chapters[idx]
        // Mirror the backend's idempotency: if already at the target,
        // updated_at is left alone. Otherwise rewrite status only;
        // draft_text / structured_prompt are explicitly preserved.
        if c.status != targetStatus {
            c.status = targetStatus
            c.updatedAt = Date()
            chapters[idx] = c
        }
        return c
    }

    public func listAgentLogs(
        chapterId: String?,
        agentName: String?,
        limit: Int,
        before: Date?
    ) async throws -> [AgentLog] {
        recordCall("listAgentLogs")
        try maybeThrow()
        var filtered = agentLogs
        if let chapterId {
            filtered = filtered.filter { $0.chapterId == chapterId }
        }
        if let agentName {
            filtered = filtered.filter { $0.agentName == agentName }
        }
        if let before {
            filtered = filtered.filter { $0.createdAt < before }
        }
        return Array(filtered.prefix(limit))
    }

    // MARK: - Provider Keys

    private func mask(_ apiKey: String) -> String {
        // Match the backend's `****xxxx` masking rule (last 4 chars).
        let tail = apiKey.suffix(4)
        return "****\(tail)"
    }

    public func listProviderKeys() async throws -> [ProviderKey] {
        recordCall("listProviderKeys")
        return try locked {
            try maybeThrow()
            return providerKeys
        }
    }

    public func createProviderKey(_ payload: ProviderKeyCreate) async throws -> ProviderKey {
        recordCall("createProviderKey")
        try maybeThrow()
        let key = ProviderKey(
            id: UUID().uuidString,
            keyLabel: payload.keyLabel,
            providerHint: payload.providerHint,
            baseUrl: payload.baseUrl,
            apiKey: mask(payload.apiKey),
            modelName: payload.modelName,
            agentRole: payload.agentRole,
            createdAt: Date(),
            updatedAt: Date()
        )
        providerKeys.append(key)
        return key
    }

    public func updateProviderKey(id: String, payload: ProviderKeyUpdate) async throws -> ProviderKey {
        recordCall("updateProviderKey")
        try maybeThrow()
        guard let idx = providerKeys.firstIndex(where: { $0.id == id }) else {
            throw AppError.notFound("provider_key")
        }
        var key = providerKeys[idx]
        if let v = payload.keyLabel { key.keyLabel = v }
        if let v = payload.providerHint { key.providerHint = v }
        if let v = payload.baseUrl { key.baseUrl = v }
        if let v = payload.apiKey { key.apiKey = mask(v) }
        if let v = payload.modelName { key.modelName = v }
        // §5.M / M-2 三态 agentRole(详见 ProviderKeyUpdate):
        switch payload.agentRole {
        case .untouched:
            break
        case .set(let role):
            key.agentRole = role
        case .clear:
            key.agentRole = nil
        }
        key.updatedAt = Date()
        providerKeys[idx] = key
        return key
    }

    public func deleteProviderKey(id: String) async throws {
        recordCall("deleteProviderKey")
        try maybeThrow()
        providerKeys.removeAll { $0.id == id }
        if activeProviderKeyId == id { activeProviderKeyId = nil }
        // §5.M / M-1 后端 DELETE 行为:同时清三个 per-agent slot。
        for role in AgentRole.allCases where activeAgentKeyIds[role] == id {
            activeAgentKeyIds[role] = nil
        }
    }

    public func getActiveProviderKey() async throws -> ActiveProviderKeySummary {
        recordCall("getActiveProviderKey")
        return try locked {
            try maybeThrow()
            guard let id = activeProviderKeyId,
                  let key = providerKeys.first(where: { $0.id == id }) else {
                return ActiveProviderKeySummary()
            }
            return ActiveProviderKeySummary(
                activeProviderKeyId: key.id,
                keyLabel: key.keyLabel,
                providerHint: key.providerHint,
                modelName: key.modelName,
                apiKeyMask: key.apiKey
            )
        }
    }

    public func setActiveProviderKey(id: String) async throws -> ActiveProviderKeySummary {
        recordCall("setActiveProviderKey")
        try maybeThrow()
        guard let key = providerKeys.first(where: { $0.id == id }) else {
            throw AppError.notFound("provider_key")
        }
        activeProviderKeyId = id
        return ActiveProviderKeySummary(
            activeProviderKeyId: key.id,
            keyLabel: key.keyLabel,
            providerHint: key.providerHint,
            modelName: key.modelName,
            apiKeyMask: key.apiKey
        )
    }

    // MARK: - Per-Agent active key (§5.M / M-1 mock)

    /// Last `(role, providerKeyId?)` passed to `setActiveAgentKey`,for tests
    /// asserting the Swift-side encoding(尤其 nil 是否真的发到后端而不是
    /// 被序列化省略)。
    public var lastSetActiveAgentPayload: (role: AgentRole, providerKeyId: String?)?

    public func getActiveAgentKey(agentRole: AgentRole) async throws -> ActiveAgentKeyRead {
        recordCall("getActiveAgentKey")
        return try locked {
            try maybeThrow()
            let boundId = activeAgentKeyIds[agentRole] ?? nil
            guard let id = boundId,
                  let key = providerKeys.first(where: { $0.id == id }) else {
                return ActiveAgentKeyRead(agentRole: agentRole)
            }
            return ActiveAgentKeyRead(
                agentRole: agentRole,
                activeProviderKeyId: key.id,
                keyLabel: key.keyLabel,
                providerHint: key.providerHint,
                modelName: key.modelName,
                apiKeyMask: key.apiKey
            )
        }
    }

    public func setActiveAgentKey(
        agentRole: AgentRole,
        providerKeyId: String?
    ) async throws -> ActiveAgentKeyRead {
        recordCall("setActiveAgentKey")
        return try locked {
            lastSetActiveAgentPayload = (agentRole, providerKeyId)
            try maybeThrow()
            if let id = providerKeyId {
                guard let key = providerKeys.first(where: { $0.id == id }) else {
                    throw AppError.notFound("provider_key")
                }
                // §5.M / M-1 后端约束:绑定到某 Agent 的 key 不能跨 slot 激活。
                if let bound = key.agentRole, bound != agentRole {
                    throw AppError.conflict("LLM Key 「\(key.keyLabel)」绑定到 \(bound.displayName),不能激活到 \(agentRole.displayName) slot")
                }
                activeAgentKeyIds[agentRole] = id
            } else {
                // null = 显式清回 generic fallback
                activeAgentKeyIds[agentRole] = nil
            }
            // 内联返回最新 ActiveAgentKeyRead 而不递归调 self.getActiveAgentKey(...),
            // 避免重复 recordCall / 嵌套加锁。
            let boundId = activeAgentKeyIds[agentRole] ?? nil
            guard let id = boundId,
                  let key = providerKeys.first(where: { $0.id == id }) else {
                return ActiveAgentKeyRead(agentRole: agentRole)
            }
            return ActiveAgentKeyRead(
                agentRole: agentRole,
                activeProviderKeyId: key.id,
                keyLabel: key.keyLabel,
                providerHint: key.providerHint,
                modelName: key.modelName,
                apiKeyMask: key.apiKey
            )
        }
    }

    // MARK: - Export (§5.F mock)

    /// Captures the last ``exportBook`` arguments so tests can assert the
    /// query parameters made it through encoding unchanged. Mirrors the
    /// ``lastImportPayload`` / ``lastSetActiveAgentPayload`` hooks.
    public var lastExportBookCall: (id: String, format: ExportFormat, includeDrafts: Bool)?
    /// Same idea for ``exportChapter``.
    public var lastExportChapterCall: (id: String, format: ExportFormat)?

    public func exportBook(
        id: String,
        format: ExportFormat,
        includeDrafts: Bool
    ) async throws -> (data: Data, suggestedFilename: String) {
        recordCall("exportBook")
        lastExportBookCall = (id, format, includeDrafts)
        try maybeThrow()
        guard let book = books.first(where: { $0.id == id }) else {
            throw AppError.notFound("book")
        }
        let filename = "\(book.title).\(format.fileExtension)"
        // Sample body: just the book title — enough for tests to assert
        // round-tripping. Production app uses the real export endpoint.
        let data = Data("# \(book.title)\n".utf8)
        return (data, filename)
    }

    public func exportChapter(
        id: String,
        format: ExportFormat
    ) async throws -> (data: Data, suggestedFilename: String) {
        recordCall("exportChapter")
        lastExportChapterCall = (id, format)
        try maybeThrow()
        guard let chapter = chapters.first(where: { $0.id == id }) else {
            throw AppError.notFound("chapter")
        }
        let title = (chapter.title ?? "").isEmpty
            ? "第\(chapter.index)章"
            : "第\(chapter.index)章·\(chapter.title!)"
        let filename = "\(title).\(format.fileExtension)"
        let data = Data("## \(title)\n".utf8)
        return (data, filename)
    }
}
