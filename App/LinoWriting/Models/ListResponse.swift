import Foundation

/// Generic { "items": [...] } list wrapper used by every list endpoint.
public struct ListResponse<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public init(items: [Item]) { self.items = items }
}
