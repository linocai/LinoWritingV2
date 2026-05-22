import Foundation

public struct AgentLog: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let id: String
    public let chapterId: String?
    public let agentName: String
    public let inputPreview: String?
    public let outputPreview: String?
    public let latencyMs: Int?
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let error: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case chapterId = "chapter_id"
        case agentName = "agent_name"
        case inputPreview = "input_preview"
        case outputPreview = "output_preview"
        case latencyMs = "latency_ms"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case error
        case createdAt = "created_at"
    }
}
