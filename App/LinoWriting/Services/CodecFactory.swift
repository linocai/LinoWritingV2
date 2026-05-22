import Foundation

/// Shared JSON encoders/decoders configured for ISO 8601 (with optional fractional seconds).
public enum CodecFactory {

    /// ISO 8601 formatter that gracefully accepts the variants the backend may emit.
    /// Tries the most permissive form (fractional seconds) first, then plain.
    static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // Fallback: Date(timeIntervalSince1970) if it's a number-shaped string.
        if let ts = Double(s) { return Date(timeIntervalSince1970: ts) }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO date: \(s)")
    }

    static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var c = encoder.singleValueContainer()
        try c.encode(isoFractional.string(from: date))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = dateDecodingStrategy
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = dateEncodingStrategy
        return e
    }
}
