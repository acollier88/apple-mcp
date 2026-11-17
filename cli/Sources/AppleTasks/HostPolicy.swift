import Darwin
import Foundation

/// SSRF gate for agent-supplied http(s) URLs (`WebGet.request`).
///
/// Three layers, all applied unless `APPLE_TASKS_ALLOW_PRIVATE_URLS=1`
/// (escape hatch for LAN watches — checked in `WebGet`, not here, so these
/// functions stay pure):
///
/// 1. `refusal(for:)` — literal host: IP literals (including legacy
///    `inet_aton` forms and IPv6 with embedded IPv4) and reserved names.
/// 2. `refusal(for:resolve:)` — (1) plus DNS: every A/AAAA answer must be
///    public, and a name that does not resolve is refused. Runs before the
///    request and again on every redirect hop.
/// 3. `refusal(remoteAddress:)` — the address URLSession actually connected
///    to (`URLSessionTaskTransactionMetrics.remoteAddress`), checked after
///    the load and before the body is handed back. This catches a DNS
///    rebind between (2) and the connect, but only after the request was
///    sent — see docs/security.md "SSRF" for the remaining window.
enum HostPolicy {
    /// A resolved address: IPv4 in host order, IPv6 as 16 network-order bytes.
    enum Address: Equatable, CustomStringConvertible {
        case v4(UInt32)
        case v6([UInt8])

        var description: String {
            switch self {
            case .v4(let ip):
                return "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
            case .v6(let bytes):
                var addr = in6_addr()
                withUnsafeMutableBytes(of: &addr) { raw in
                    for (i, b) in bytes.prefix(16).enumerated() { raw[i] = b }
                }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return "?" }
                return String(cString: buf)
            }
        }
    }

    /// Hostname → every address it resolves to. Injectable so tests never
    /// touch the network; production uses `systemResolve` (getaddrinfo).
    typealias Resolver = (String) throws -> [Address]

    struct ResolveError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Layer 1: literal host

    static func refusal(for url: URL) -> String? {
        switch classify(url) {
        case .refused(let reason): return reason
        case .literal, .name: return nil
        }
    }

    // MARK: - Layer 2: literal host + DNS

    static func refusal(for url: URL, resolve: Resolver) -> String? {
        switch classify(url) {
        case .refused(let reason):
            return reason
        case .literal:
            return nil
        case .name(let host):
            let addresses: [Address]
            do {
                addresses = try resolve(host)
            } catch {
                // Fail closed: URLSession would resolve again itself, and a
                // name that fails for us but answers for it is exactly the
                // shape of a rebinding attempt.
                return "could not resolve host '\(host)': \(error)"
            }
            guard !addresses.isEmpty else { return "host '\(host)' has no addresses" }
            for address in addresses {
                if let reason = refusal(address: address) {
                    return "host '\(host)' resolves to \(address) (\(reason))"
                }
            }
            return nil
        }
    }

    /// getaddrinfo over A and AAAA; every answer is returned.
    static func systemResolve(_ host: String) throws -> [Address] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0 else {
            throw ResolveError(description: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }
        var out: [Address] = []
        var cursor = result
        while let info = cursor?.pointee {
            if let sa = info.ai_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                    out.append(.v4(UInt32(bigEndian: sin.sin_addr.s_addr)))
                case AF_INET6:
                    var sin6 = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in6.self).pointee
                    let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                    out.append(.v6(bytes))
                default:
                    break
                }
            }
            cursor = info.ai_next
        }
        return out
    }

    // MARK: - Layer 3: the address actually connected to

    /// `remoteAddress` from URLSession metrics ("1.2.3.4", "2606:…", maybe
    /// with a `%scope`). Unparseable is refused — we cannot vouch for it.
    static func refusal(remoteAddress raw: String) -> String? {
        var text = raw
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
        if let v4 = parseDottedQuad(text) { return refusal(address: .v4(v4)) }
        if let v6 = parseIPv6(text) { return refusal(address: .v6(v6)) }
        return "unparseable remote address '\(raw)'"
    }

    // MARK: - Address policy

    static func refusal(address: Address) -> String? {
        switch address {
        case .v4(let ip): return refusal(ipv4: ip)
        case .v6(let bytes): return refusal(ipv6: bytes)
        }
    }

    static func allowsPrivateURLs(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["APPLE_TASKS_ALLOW_PRIVATE_URLS"] == "1"
    }

    // MARK: - Host classification

    private enum HostClass {
        case refused(String)
        case literal
        case name(String)
    }

    private static func classify(_ url: URL) -> HostClass {
        let raw = url.host ?? ""
        let host = raw.hasPrefix("[") && raw.hasSuffix("]")
            ? String(raw.dropFirst().dropLast())
            : raw
        if host.isEmpty { return .refused("empty host") }

        if let ipv4 = parseIPv4(host) {
            return refusal(ipv4: ipv4).map(HostClass.refused) ?? .literal
        }
        if let ipv6 = parseIPv6(host) {
            return refusal(ipv6: ipv6).map(HostClass.refused) ?? .literal
        }

        // "localhost." is the same name as "localhost" to the resolver.
        var lower = host.lowercased()
        while lower.hasSuffix(".") { lower.removeLast() }
        if lower.isEmpty { return .refused("empty host") }
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return .refused("localhost hostname")
        }
        if lower.hasSuffix(".local") {
            return .refused(".local hostname")
        }
        if lower.hasSuffix(".internal") {
            return .refused(".internal hostname")
        }
        return .name(host)
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

    /// Strict dotted quad, for addresses the OS printed itself.
    private static func parseDottedQuad(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
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
        if matches(ip, network: 0xE000_0000, prefix: 4) { return "multicast address" }     // 224.0.0.0/4
        if matches(ip, network: 0xF000_0000, prefix: 4) { return "reserved address" }      // 240.0.0.0/4 (+ broadcast)
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
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func v4(_ b: [UInt8], at i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    /// IPv4 carried inside an IPv6 address, for the forms a host or a
    /// translator on the path would actually deliver to that IPv4:
    /// mapped `::ffff:0:0/96`, SIIT-translated `::ffff:0:0:0/96`, deprecated
    /// compatible `::/96`, NAT64 `64:ff9b::/96` and `64:ff9b:1::/48`, 6to4
    /// `2002::/16`, and the Teredo client (`2001:0::/32`, bits inverted).
    static func embeddedIPv4(_ b: [UInt8]) -> UInt32? {
        let zeros = { (range: Range<Int>) in b[range].allSatisfy { $0 == 0 } }
        if zeros(0..<10) && b[10] == 0xFF && b[11] == 0xFF { return v4(b, at: 12) }          // ::ffff:a.b.c.d
        if zeros(0..<8) && b[8] == 0xFF && b[9] == 0xFF && zeros(10..<12) { return v4(b, at: 12) } // ::ffff:0:a.b.c.d
        if zeros(0..<12) {
            // ::a.b.c.d — but not :: or ::1, which have their own meaning.
            let ip = v4(b, at: 12)
            return ip > 1 ? ip : nil
        }
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B {
            if zeros(4..<12) { return v4(b, at: 12) }                                          // 64:ff9b::/96
            if b[4] == 0x00 && b[5] == 0x01 {                                                  // 64:ff9b:1::/48
                return v4(b, at: 12)
            }
        }
        if b[0] == 0x20 && b[1] == 0x02 { return v4(b, at: 2) }                               // 2002:aabb:ccdd::/48
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 {                     // Teredo
            return ~v4(b, at: 12)
        }
        return nil
    }

    private static func refusal(ipv6 b: [UInt8]) -> String? {
        guard b.count == 16 else { return "malformed IPv6 address" }
        if b.allSatisfy({ $0 == 0 }) { return "unspecified address" }                      // ::
        if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return "loopback address" } // ::1
        if let embedded = embeddedIPv4(b), let reason = refusal(ipv4: embedded) {
            return "\(reason) (embedded IPv4)"
        }
        if b[0] & 0xFE == 0xFC { return "unique-local address" }                           // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return "link-local address" }             // fe80::/10
        if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 { return "site-local address" }             // fec0::/10
        if b[0] == 0xFF { return "multicast address" }                                     // ff00::/8
        return nil
    }
}
