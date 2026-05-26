import Foundation
import Darwin

/// v0.8 §5.U.2 client-side network self-test.
///
/// LinoI ships with a production default of `https://lw.linotsai.top`, but
/// the author's home network resolves that hostname to `198.18.16.246`
/// (router / WARP / VPN hijacking DNS). The fix is a one-line `/etc/hosts`
/// override — but the user has to know they're being hijacked first. This
/// probe powers the "网络自检" sub-section in Settings → Connection (macOS
/// only): it resolves the configured hostname via `getaddrinfo()` and
/// flags any deviation from the HZ origin IP list in
/// `Settings.trustedBackendIPs`.
///
/// All entry points are `async` so the UI can show a spinner without
/// blocking the main actor on a blocking BSD socket call. The DNS lookup
/// runs on a background dispatch queue; the TLS / health probe just
/// piggybacks on `URLSession`.
public enum NetworkProbe {

    // MARK: - DNS

    /// Result of resolving a hostname. The `isTrusted` flag is the
    /// banner trigger: if `false`, Settings shows the red hijack warning.
    public struct DNSResult: Sendable, Equatable {
        public let host: String
        public let addresses: [String]
        public let isTrusted: Bool
        /// Non-nil when `getaddrinfo()` itself errored (NXDOMAIN, no
        /// network, etc.). Distinct from "resolved but wrong IP".
        public let resolveError: String?

        public var primaryAddress: String? { addresses.first }
    }

    /// Resolve `host` via `getaddrinfo()` and compare against
    /// `Settings.trustedBackendIPs`. Returns deterministically — never
    /// throws — so the UI can render any failure mode the same way.
    ///
    /// Implementation note: `getaddrinfo()` is blocking, so we hop to a
    /// background queue. We deliberately avoid `Network.framework`'s
    /// `NWConnection` host endpoint because it doesn't expose the
    /// resolved address before connect(), and an async DNS test is the
    /// whole point of this view.
    public static func resolve(
        host: String,
        trustedAddresses: [String] = Settings.trustedBackendIPs
    ) async -> DNSResult {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return DNSResult(host: host, addresses: [], isTrusted: false, resolveError: "hostname 为空")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = blockingResolve(host: trimmed, trustedAddresses: trustedAddresses)
                continuation.resume(returning: result)
            }
        }
    }

    /// Blocking helper — only call from a background queue. Pulled out
    /// as a non-`async` function so it's straightforward to unit-test in
    /// the future (synchronous, no continuation plumbing).
    private static func blockingResolve(host: String, trustedAddresses: [String]) -> DNSResult {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // accept both IPv4 + IPv6
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>? = nil
        let status = getaddrinfo(host, nil, &hints, &info)
        defer { if info != nil { freeaddrinfo(info) } }

        guard status == 0 else {
            let msg = String(cString: gai_strerror(status))
            return DNSResult(host: host, addresses: [], isTrusted: false, resolveError: msg)
        }

        var addresses: [String] = []
        var cursor = info
        while let node = cursor {
            if let addr = formatAddress(node.pointee) {
                if !addresses.contains(addr) { addresses.append(addr) }
            }
            cursor = node.pointee.ai_next
        }

        if addresses.isEmpty {
            return DNSResult(host: host, addresses: [], isTrusted: false, resolveError: "解析为空")
        }

        // "Trusted" means **every** resolved address is in the allow-list.
        // Common hijack signature is a single 198.18.x.y captive-portal
        // address replacing the real origin, so this is the simplest
        // sound check.
        let trustedSet = Set(trustedAddresses)
        let isTrusted = addresses.allSatisfy { trustedSet.contains($0) }
        return DNSResult(host: host, addresses: addresses, isTrusted: isTrusted, resolveError: nil)
    }

    private static func formatAddress(_ node: addrinfo) -> String? {
        guard let sa = node.ai_addr else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

        switch Int32(node.ai_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var addr = p.pointee.sin_addr
                guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
        default:
            return nil
        }
    }

    // MARK: - TLS / health probe (nice-to-have)

    public struct HealthResult: Sendable, Equatable {
        /// HTTP status code returned by the server. `nil` when the
        /// transport itself failed (no TLS, no route, DNS hijack to
        /// something that isn't even a HTTP server, etc.).
        public let statusCode: Int?
        public let elapsedMS: Int
        public let transportError: String?
    }

    /// Hits `<baseURL>/api/v1/health` with no auth header. A `200` proves
    /// the cloud backend is reachable; a `401` proves it's reachable and
    /// the auth middleware is alive (which is still "good — backend is
    /// up, you just need to fill in the token"). Anything else is
    /// surfaced to the user as-is.
    public static func probeHealth(baseURL: URL) async -> HealthResult {
        let healthURL = baseURL.appendingPathComponent("api/v1/health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        // Keep the timeout short — author is staring at a spinner.
        request.timeoutInterval = 8

        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode
            return HealthResult(statusCode: code, elapsedMS: elapsed, transportError: nil)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return HealthResult(statusCode: nil, elapsedMS: elapsed, transportError: error.localizedDescription)
        }
    }
}
