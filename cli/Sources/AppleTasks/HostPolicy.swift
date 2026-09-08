import Darwin
import Foundation

/// Literal-host SSRF gate for agent-supplied http(s) URLs (`WebGet.request`).
/// Does **not** resolve DNS — rebinding is out of scope.
/// Escape hatch (LAN watches): `APPLE_TASKS_ALLOW_PRIVATE_URLS=1` skips this
/// in `WebGet` (not here — `refusal(for:)` stays pure).
enum HostPolicy {
    static func refusal(for url: URL) -> String? {
        let raw = url.host ?? ""
        let host = raw.hasPrefix("[") && raw.hasSuffix("]")
            ? String(raw.dropFirst().dropLast())
            : raw
        if host.isEmpty { return "empty host" }

        if let ipv4 = parseIPv4(host) {
            return refusal(ipv4: ipv4)
        }
        if let ipv6 = parseIPv6(host) {
            return refusal(ipv6: ipv6)
        }

        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return "localhost hostname"
        }
        if lower.hasSuffix(".local") {
            return ".local hostname"
        }
        if lower.hasSuffix(".internal") {
            return ".internal hostname"
        }
        return nil
    }

    static func allowsPrivateURLs(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["APPLE_TASKS_ALLOW_PRIVATE_URLS"] == "1"
    }

    // MARK: - IPv4 (host-order)

    /// `inet_aton`, not `inet_pton`: resolvers accept the legacy shorthand,
    /// octal, hex, and single-integer forms (`127.1`, `0177.0.0.1`, `0x7f000001`,
    /// `2130706433`), so a strict dotted-quad parser would let them through
    /// as "hostnames" and CFNetwork would still connect to loopback.
    private static func parseIPv4(_ host: String) -> UInt32? {
        guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" })
        else { return nil }
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func refusal(ipv4 ip: UInt32) -> String? {
        if matches(ip, network: 0x7F00_0000, prefix: 8) { return "loopback address" }      // 127.0.0.0/8
        if matches(ip, network: 0x0A00_0000, prefix: 8) { return "private address" }       // 10.0.0.0/8
        if matches(ip, network: 0xAC10_0000, prefix: 12) { return "private address" }      // 172.16.0.0/12
        if matches(ip, network: 0xC0A8_0000, prefix: 16) { return "private address" }      // 192.168.0.0/16
        if matches(ip, network: 0xA9FE_0000, prefix: 16) { return "link-local address" }   // 169.254.0.0/16
        if matches(ip, network: 0x0000_0000, prefix: 8) { return "unspecified address" }   // 0.0.0.0/8
        if matches(ip, network: 0x6440_0000, prefix: 10) { return "CGNAT address" }        // 100.64.0.0/10
        return nil
    }

    private static func matches(_ ip: UInt32, network: UInt32, prefix: Int) -> Bool {
        let mask = prefix == 0 ? UInt32(0) : ~UInt32(0) << (32 - prefix)
        return (ip & mask) == network
    }

    // MARK: - IPv6

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let a = addr.__u6_addr.__u6_addr8
        return [a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7,
                a.8, a.9, a.10, a.11, a.12, a.13, a.14, a.15]
    }

    private static func refusal(ipv6 b: [UInt8]) -> String? {
        // IPv4-mapped (::ffff:a.b.c.d) uses the same v4 ranges.
        if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            let ipv4 = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16)
                | (UInt32(b[14]) << 8) | UInt32(b[15])
            return refusal(ipv4: ipv4)
        }
        if b.allSatisfy({ $0 == 0 }) { return "unspecified address" }                      // ::
        if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return "loopback address" } // ::1
        if b[0] & 0xFE == 0xFC { return "unique-local address" }                           // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return "link-local address" }             // fe80::/10
        return nil
    }
}
