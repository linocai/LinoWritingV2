import Foundation
import Security

/// Stores the API base URL and bearer token in the macOS / iOS Keychain.
/// Items are scoped to a custom service identifier so test runs / preview hosts don't collide.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    private let service: String
    private let baseURLKey = "api_base_url"
    private let tokenKey = "api_token"

    public init(service: String = "com.lino.linowriting") {
        self.service = service
    }

    // MARK: - Public

    public var baseURL: URL? {
        get { read(baseURLKey).flatMap { URL(string: $0) } }
        set { write(baseURLKey, newValue?.absoluteString) }
    }

    public var token: String? {
        get { read(tokenKey) }
        set { write(tokenKey, newValue) }
    }

    public var isConfigured: Bool {
        guard let url = baseURL, !(url.absoluteString.isEmpty), let t = token, !t.isEmpty else { return false }
        return true
    }

    public func clear() {
        write(baseURLKey, nil)
        write(tokenKey, nil)
    }

    // MARK: - Private SecItem helpers

    private func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Always wipe first to keep the call site simple.
        SecItemDelete(baseQuery as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
