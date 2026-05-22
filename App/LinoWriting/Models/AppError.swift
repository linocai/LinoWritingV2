import Foundation

/// Application-level error type. Mirrors the backend error envelope
/// described in §3.1 of `PLAN_FRONTEND.md` plus local transport failures.
public enum AppError: Error, Equatable, Sendable {
    case validation(String)
    case notFound(String)
    case conflict(String)
    case upstream(String, retryable: Bool)
    case unauthorized(String)
    case server(String)
    case transport(String)
    case decoding(String)
    case cancelled

    public var message: String {
        switch self {
        case .validation(let m), .notFound(let m), .conflict(let m),
             .unauthorized(let m), .server(let m), .transport(let m),
             .decoding(let m):
            return m
        case .upstream(let m, _): return m
        case .cancelled: return "请求已取消"
        }
    }

    public var retryable: Bool {
        switch self {
        case .upstream(_, let r): return r
        case .transport, .server: return true
        default: return false
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

/// Backend error envelope: `{ "error": { "kind": ..., "message": ..., "retryable": ..., "details": ... } }`.
public struct BackendErrorEnvelope: Codable, Sendable {
    public struct Body: Codable, Sendable {
        public let kind: String
        public let message: String
        public let retryable: Bool?
        public let details: JSONValue?
    }
    public let error: Body
}
