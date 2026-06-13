import Foundation

/// v1.0.0 EE §5.1 / §5.5 — the book-level outline (1 book : 1 outline).
///
/// Plain prose only: the backend stores exactly `raw_text` (the author's
/// ~5000-word outline) + timestamps. There is **no** digest / structured
/// parse — the App ingests / reads back / hand-edits the verbatim text.
/// `rawText` is nullable because a freshly-created (or never-ingested)
/// outline row can carry a null body; the panel renders that as "empty".
///
/// Mirrors `BookOutlineRead` on the wire:
/// `{ id, book_id, raw_text, created_at, updated_at }`.
public struct BookOutline: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let bookId: String
    public var rawText: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case rawText = "raw_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        bookId: String,
        rawText: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.rawText = rawText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Body for `POST /books/{id}/outline/ingest` and `PATCH /books/{id}/outline`.
/// Both endpoints share the single-field `{ raw_text }` shape (ingest upserts,
/// PATCH whitelists `raw_text` only — §5.1). `rawText` is optional to mirror
/// the backend `OutlineIngest` / `OutlinePatch` schemas; the App always sends
/// a concrete value (possibly empty string) when the author saves.
public struct OutlineWriteRequest: Codable, Sendable {
    public var rawText: String?

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
    }

    public init(rawText: String?) {
        self.rawText = rawText
    }
}

/// Envelope for the three outline endpoints: `{ "outline": <BookOutline> | null }`.
/// `GET /outline` can return `{ "outline": null }` when the book never ingested
/// one, so `outline` is optional here.
public struct OutlineEnvelope: Codable, Sendable {
    public var outline: BookOutline?

    public init(outline: BookOutline?) {
        self.outline = outline
    }
}
