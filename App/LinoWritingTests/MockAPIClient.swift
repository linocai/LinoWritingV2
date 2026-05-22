import Foundation
@testable import LinoWriting

/// Hand-rolled mock that stores in-memory state and lets tests assert on calls.
public final class MockAPIClient: APIClientProtocol, @unchecked Sendable {

    public var books: [Book] = []
    public var characters: [Character] = []
    public var chapters: [Chapter] = []
    public var timelineEvents: [TimelineEvent] = []
    public var agentLogs: [AgentLog] = []

    public var calls: [String] = []

    // Pluggable behaviour for flow tests.
    public var onExpand: ((String, Bool) -> Chapter)?
    public var onWrite: ((String) -> [SSEEvent])?
    public var onFinalize: ((String) -> FinalizeResult)?
    public var onReopen: ((String) -> Chapter)?

    public var errorToThrow: AppError?

    public init() {}

    private func recordCall(_ name: String) { calls.append(name) }

    private func maybeThrow() throws {
        if let e = errorToThrow { throw e }
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
        if let s = req.styleDirective { book.styleDirective = s }
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

    public func listTimeline(characterId: String, limit: Int, before: Date?) async throws -> [TimelineEvent] {
        recordCall("listTimeline")
        try maybeThrow()
        var events = timelineEvents.filter { $0.characterId == characterId }
        if let before { events = events.filter { $0.createdAt < before } }
        return Array(events.prefix(limit))
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
            chapterGoal: "Mock expanded goal",
            mustHappen: ["事件 A"],
            mustNotHappen: [],
            charactersInvolved: []
        )
        c.status = .promptReady
        c.updatedAt = Date()
        chapters[idx] = c
        return c
    }

    public func writeStream(chapterId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        recordCall("writeStream")
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
                    .done(chapter: c)
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
                    if case .error(let e) = event {
                        continuation.finish(throwing: e); return
                    }
                }
                continuation.finish()
            }
        }
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

    public func listAgentLogs(chapterId: String?, limit: Int) async throws -> [AgentLog] {
        recordCall("listAgentLogs")
        try maybeThrow()
        return Array(agentLogs.prefix(limit))
    }
}
