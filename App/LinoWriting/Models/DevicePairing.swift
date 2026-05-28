import Foundation

/// DTOs for the v0.9 §5.W device-pairing flow.
///
/// Four backend endpoints back these (§5.W.4, shipped in W-1):
///   - `POST /api/v1/auth/pair_initiate`  → `PairInitiateResponse`
///   - `POST /api/v1/auth/pair_confirm`   → `PairConfirmResponse`
///   - `GET  /api/v1/auth/devices`        → `{ "items": [DeviceInfo] }`
///   - `DELETE /api/v1/auth/devices/{id}` → 204
///
/// All field mapping is done with explicit `CodingKeys` (snake_case ↔
/// camelCase), matching the project convention — `CodecFactory` does NOT
/// enable `.convertFromSnakeCase`, so every model spells the wire keys out.

/// Response of `POST /api/v1/auth/pair_initiate`.
///
/// `code` is a zero-padded 6-digit string (leading zeros preserved on the
/// wire). `expiresAt` is ISO-8601 UTC; the macOS dialog draws a countdown
/// clock off of it (10-minute TTL per §5.W.2).
public struct PairInitiateResponse: Codable, Equatable, Sendable {
    public let code: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// Body of `POST /api/v1/auth/pair_confirm` — the Bearer-less endpoint
/// (§5.W.4). A new device exchanges the 6-digit code for a fresh device
/// token.
///
/// `deviceName` is author-supplied (or defaulted to `UIDevice.current.name`
/// / `Host.current().localizedName` on the client). The backend constrains
/// `code` to exactly 6 ASCII digits and `deviceName` to 1–80 chars (422 on
/// violation), so the client should pre-trim before sending.
public struct PairConfirmRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceName: String

    enum CodingKeys: String, CodingKey {
        case code
        case deviceName = "device_name"
    }

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

/// Success body of `POST /api/v1/auth/pair_confirm`.
///
/// `token` is the plaintext device token (64-char hex) and is returned
/// EXACTLY ONCE — the client must persist it to Keychain immediately. The
/// DB only ever stores the Fernet ciphertext.
public struct PairConfirmResponse: Codable, Equatable, Sendable {
    public let deviceId: String
    public let token: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
    }

    public init(deviceId: String, token: String) {
        self.deviceId = deviceId
        self.token = token
    }
}

/// One row of `GET /api/v1/auth/devices`.
///
/// `lastUsedAt` is nullable: a freshly-paired device that has not yet made
/// an authenticated request has `null` here, which the macOS list renders
/// as "从未". The wire payload deliberately never includes the token
/// ciphertext.
public struct DeviceInfo: Codable, Equatable, Identifiable, Sendable, Hashable {
    public let deviceId: String
    public let deviceName: String
    public let createdAt: Date
    public let lastUsedAt: Date?

    /// `Identifiable` conformance — `deviceId` is the stable UUID PK.
    public var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    public init(
        deviceId: String,
        deviceName: String,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceId = try c.decode(String.self, forKey: .deviceId)
        self.deviceName = try c.decode(String.self, forKey: .deviceName)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        // `last_used_at` may be absent (older payload) or explicitly null —
        // `decodeIfPresent` covers both (sentinel "从未" in the UI either way).
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// The payload encoded inside the macOS-generated QR code (§5.W.2).
///
/// Wire form is JSON → base64. The iOS scanner (W-3) decodes base64 → JSON
/// → reads `u` / `c` / `ip`. Compact single-letter keys keep the QR module
/// count low so the code stays scannable at a modest on-screen size:
///   - `u`  — backend base URL (string)
///   - `c`  — 6-digit pairing code (string)
///   - `ip` — optional trusted IP override (omitted when unknown)
public struct PairingPayload: Codable, Equatable, Sendable {
    public let url: String
    public let code: String
    public let ipOverride: String?

    enum CodingKeys: String, CodingKey {
        case url = "u"
        case code = "c"
        case ipOverride = "ip"
    }

    public init(url: String, code: String, ipOverride: String? = nil) {
        self.url = url
        self.code = code
        self.ipOverride = ipOverride
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(code, forKey: .code)
        // Omit `ip` entirely when unknown (matches §5.W.2 "可选" semantics:
        // the iOS side treats a missing key the same as an explicit null).
        try c.encodeIfPresent(ipOverride, forKey: .ipOverride)
    }

    /// Encode this payload as the base64 string embedded in the QR code.
    /// Returns `nil` only if JSON encoding fails (it won't for these
    /// all-String fields, but the optional keeps callers honest).
    public func base64Encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
    }

    /// Inverse of `base64Encoded()` — used by the iOS scanner (W-3) to turn
    /// a scanned QR string back into a payload. Returns `nil` on malformed
    /// base64 / JSON so the caller can fall back to manual entry.
    public static func fromBase64(_ string: String) -> PairingPayload? {
        guard let data = Data(base64Encoded: string),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data)
        else { return nil }
        return payload
    }
}
