import Foundation

public enum ErrorMapping {

    /// Map an HTTP response (status + body) into a domain `AppError`.
    /// If the body matches the §3.1 envelope, its `kind` drives the variant.
    public static func map(status: Int, body: Data) -> AppError {
        if let envelope = try? CodecFactory.makeDecoder().decode(BackendErrorEnvelope.self, from: body) {
            let msg = envelope.error.message
            let retryable = envelope.error.retryable ?? false
            switch envelope.error.kind {
            case "validation": return .validation(msg)
            case "not_found": return .notFound(msg)
            case "conflict": return .conflict(msg)
            case "upstream": return .upstream(msg, retryable: retryable)
            case "unauthorized": return .unauthorized(msg)
            case "internal": return .server(msg)
            default: return .server(msg)
            }
        }
        // Fallback: derive from status code.
        let text = String(data: body, encoding: .utf8) ?? ""
        switch status {
        case 400, 422: return .validation(text.isEmpty ? "请求参数无效" : text)
        case 401, 403: return .unauthorized(text.isEmpty ? "鉴权失败" : text)
        case 404: return .notFound(text.isEmpty ? "资源不存在" : text)
        case 409: return .conflict(text.isEmpty ? "状态冲突" : text)
        case 500...599: return .server(text.isEmpty ? "服务器错误 (\(status))" : text)
        default: return .server("HTTP \(status): \(text)")
        }
    }
}
