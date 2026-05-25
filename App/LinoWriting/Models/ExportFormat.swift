import Foundation

/// v0.7 §5.F — supported export formats for both ``GET
/// /books/{id}/export`` and ``GET /chapters/{id}/export``.
///
/// The ``rawValue`` matches the backend's ``Literal["markdown", "txt"]``
/// so it can be sent straight through as a ``format=`` query parameter
/// without any extra mapping layer.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case markdown
    case txt

    /// File extension to suggest when saving the response body to disk.
    /// Mirrors the backend's ``build_filename`` choice in
    /// ``Backend/app/services/exporter.py``.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .txt: return "txt"
        }
    }

    /// MIME type expected on the response. The frontend never needs to
    /// emit this (the backend sets ``Content-Type``) but we keep it
    /// here so tests can assert symmetry with the server.
    public var contentType: String {
        switch self {
        case .markdown: return "text/markdown"
        case .txt: return "text/plain"
        }
    }

    /// Human-facing label used in pickers / menus.
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .txt: return "纯文本"
        }
    }
}
