import Foundation

/// A type-erased JSON value used for free-form JSON columns (frozen_fields, live_fields, details).
/// Round-trips through `Codable` while preserving structure.
public enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Convenience accessors

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stringArrayValue: [String]? {
        guard let arr = arrayValue else { return nil }
        return arr.compactMap { $0.stringValue }
    }

    /// Treat object value as `[String: String]`. Non-string values are stringified loosely.
    public var stringDictValue: [String: String]? {
        guard let obj = objectValue else { return nil }
        var result: [String: String] = [:]
        for (k, v) in obj {
            if let s = v.stringValue { result[k] = s }
        }
        return result
    }

    public static func from(string: String) -> JSONValue { .string(string) }
    public static func from(strings: [String]) -> JSONValue { .array(strings.map { .string($0) }) }
    public static func from(dict: [String: String]) -> JSONValue {
        .object(dict.mapValues { .string($0) })
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Read a string field at the given key.
    func string(_ key: String) -> String? { self[key]?.stringValue }
    /// Read an array-of-strings field at the given key.
    func stringArray(_ key: String) -> [String] { self[key]?.stringArrayValue ?? [] }
    /// Read a `[String: String]` map at the given key.
    func stringDict(_ key: String) -> [String: String] { self[key]?.stringDictValue ?? [:] }
}
