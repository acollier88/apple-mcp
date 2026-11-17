import XCTest
@testable import apple_tasks

final class HostPolicyTests: XCTestCase {
    private func url(_ raw: String) -> URL {
        guard let url = URL(string: raw) else {
            XCTFail("unparseable URL: \(raw)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    private func assertRefused(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(HostPolicy.refusal(for: url(raw)), raw, file: file, line: line)
    }

    private func assertAllowed(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(HostPolicy.refusal(for: url(raw)), raw, file: file, line: line)
    }

    func testEmptyHostRefused() {
        assertRefused("https://")
        assertRefused("http:///path")
    }

    func testLoopbackIPv4Refused() {
        assertRefused("http://127.0.0.1/")
        assertRefused("http://127.255.255.255/")
    }

    /// Legacy inet_aton forms resolve to loopback/private too; a strict
    /// dotted-quad parser would wave them through as hostnames.
    func testLegacyIPv4FormsRefused() {
        assertRefused("http://127.1/")            // shorthand
        assertRefused("http://0177.0.0.1/")       // octal
        assertRefused("http://0x7f000001/")       // hex
        assertRefused("http://2130706433/")       // decimal
        assertRefused("http://0xA9.0xFE.0xA9.0xFE/") // metadata, hex octets
        assertRefused("http://10.1/")             // 10.0.0.1
        assertAllowed("http://1.1/")              // 1.0.0.1 — public
    }

    func testRFC1918Refused() {
        assertRefused("http://10.0.0.1/")
        assertRefused("http://10.255.1.1/")
        assertRefused("http://172.16.0.1/")
        assertRefused("http://172.31.255.1/")
        assertRefused("http://192.168.1.1/")
        assertRefused("http://192.168.0.1/")
    }

    func testLinkLocalAndMetadataRefused() {
        assertRefused("http://169.254.1.1/")
        assertRefused("http://169.254.169.254/")
    }

    func testUnspecifiedIPv4Refused() {
        assertRefused("http://0.0.0.0/")
        assertRefused("http://0.1.2.3/")
    }

    func testCGNATRefused() {
        assertRefused("http://100.64.0.1/")
        assertRefused("http://100.127.255.1/")
    }

    func testIPv6LoopbackAndUnspecifiedRefused() {
        assertRefused("http://[::1]/")
        assertRefused("http://[::]/")
    }

    func testIPv6UniqueLocalAndLinkLocalRefused() {
        assertRefused("http://[fc00::1]/")
        assertRefused("http://[fd12:3456:789a::1]/")
        assertRefused("http://[fe80::1]/")
    }

    func testLocalhostHostnamesRefused() {
        assertRefused("http://localhost/")
        assertRefused("http://LOCALHOST/")
        assertRefused("http://foo.localhost/")
    }

    func testLocalAndInternalHostnamesRefused() {
        assertRefused("http://printer.local/")
        assertRefused("http://svc.internal/")
    }

    func testPublicHostsAllowed() {
        assertAllowed("https://example.com")
        assertAllowed("https://8.8.8.8")
        assertAllowed("http://[2606:4700::1111]")
    }

    func testAdjacentPublicIPv4Allowed() {
        assertAllowed("http://11.0.0.1/")
        assertAllowed("http://172.15.255.1/")
        assertAllowed("http://172.32.0.1/")
        assertAllowed("http://100.63.255.1/")
        assertAllowed("http://100.128.0.1/")
    }

    func testIPv4MappedFollowsIPv4Policy() {
        assertRefused("http://[::ffff:127.0.0.1]/")
        assertAllowed("http://[::ffff:8.8.8.8]/")
    }

    func testEmbeddedIPv4FormsFollowIPv4Policy() {
        assertRefused("http://[::ffff:7f00:1]/")            // mapped, hex spelling
        assertRefused("http://[::ffff:0:10.0.0.1]/")        // SIIT translated
        assertRefused("http://[::127.0.0.1]/")              // deprecated compatible
        assertRefused("http://[64:ff9b::10.0.0.1]/")        // NAT64 well-known prefix
        assertRefused("http://[64:ff9b:1::a9fe:a9fe]/")     // NAT64 local-use, metadata
        assertRefused("http://[2002:7f00:1::]/")            // 6to4 of 127.0.0.1
        assertRefused("http://[2002:c0a8:101::1]/")         // 6to4 of 192.168.1.1
        assertRefused("http://[2001:0:4136:e378:8000:63bf:f5ff:fffe]/") // Teredo client 10.0.0.1
        assertAllowed("http://[64:ff9b::8.8.8.8]/")
        assertAllowed("http://[2002:808:808::1]/")          // 6to4 of 8.8.8.8
    }

    func testMulticastReservedAndSiteLocalRefused() {
        assertRefused("http://224.0.0.1/")
        assertRefused("http://255.255.255.255/")
        assertRefused("http://240.0.0.1/")
        assertRefused("http://[ff02::1]/")
        assertRefused("http://[fec0::1]/")
    }

    func testTrailingDotLocalhostRefused() {
        assertRefused("http://localhost./")
        assertRefused("http://printer.local./")
    }

    // MARK: - DNS (injected resolver; never hits the network)

    private func resolver(_ table: [String: [HostPolicy.Address]]) -> HostPolicy.Resolver {
        { host in
            guard let answer = table[host] else {
                throw HostPolicy.ResolveError(description: "NXDOMAIN")
            }
            return answer
        }
    }

    private func v6(_ text: String) -> HostPolicy.Address {
        var addr = in6_addr()
        XCTAssertEqual(inet_pton(AF_INET6, text, &addr), 1, text)
        return .v6(withUnsafeBytes(of: &addr) { Array($0) })
    }

    func testPublicNameResolvingToPublicAllowed() {
        let resolve = resolver(["example.com": [.v4(0x5DB8_D822), v6("2606:2800:220:1::1")]])
        XCTAssertNil(HostPolicy.refusal(for: url("https://example.com/x"), resolve: resolve))
    }

    func testPublicNameResolvingToLoopbackRefused() {
        let resolve = resolver(["rebind.example": [.v4(0x7F00_0001)]])
        let reason = HostPolicy.refusal(for: url("https://rebind.example/"), resolve: resolve)
        XCTAssertEqual(reason, "host 'rebind.example' resolves to 127.0.0.1 (loopback address)")
    }

    func testAnyPrivateAnswerRefused() {
        let resolve = resolver(["mixed.example": [.v4(0x0808_0808), .v4(0x0A00_0001)]])
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://mixed.example/"), resolve: resolve))
        let v6Mixed = resolver(["mixed6.example": [v6("2606:4700::1111"), v6("fd00::1")]])
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://mixed6.example/"), resolve: v6Mixed))
    }

    func testResolvedMappedIPv6Refused() {
        let resolve = resolver(["mapped.example": [v6("::ffff:169.254.169.254")]])
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://mapped.example/"), resolve: resolve))
    }

    func testUnresolvableAndEmptyAnswerRefused() {
        let resolve = resolver(["empty.example": []])
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://nx.example/"), resolve: resolve))
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://empty.example/"), resolve: resolve))
    }

    func testLiteralsAndReservedNamesSkipResolver() {
        let resolve: HostPolicy.Resolver = { host in
            XCTFail("resolver called for \(host)")
            return []
        }
        XCTAssertNil(HostPolicy.refusal(for: url("http://8.8.8.8/"), resolve: resolve))
        XCTAssertNil(HostPolicy.refusal(for: url("http://[2606:4700::1111]/"), resolve: resolve))
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://127.0.0.1/"), resolve: resolve))
        XCTAssertNotNil(HostPolicy.refusal(for: url("http://localhost/"), resolve: resolve))
    }

    func testAddressDescription() {
        XCTAssertEqual(HostPolicy.Address.v4(0xC0A8_0101).description, "192.168.1.1")
        XCTAssertEqual(v6("fe80::1").description, "fe80::1")
    }

    // MARK: - Connected-address check (URLSession metrics)

    func testRemoteAddressPolicy() {
        XCTAssertNil(HostPolicy.refusal(remoteAddress: "93.184.216.34"))
        XCTAssertNil(HostPolicy.refusal(remoteAddress: "2606:2800:220:1::1"))
        XCTAssertNotNil(HostPolicy.refusal(remoteAddress: "127.0.0.1"))
        XCTAssertNotNil(HostPolicy.refusal(remoteAddress: "::ffff:10.0.0.1"))
        XCTAssertNotNil(HostPolicy.refusal(remoteAddress: "fe80::1%en0"))
        XCTAssertNotNil(HostPolicy.refusal(remoteAddress: "[::1]"))
        XCTAssertNotNil(HostPolicy.refusal(remoteAddress: "not-an-ip"))
    }

    func testConnectedAddressHops() {
        typealias Hop = WebGetTaskDelegate.Hop
        let publicHop = Hop(isNetworkLoad: true, isProxy: false, remoteAddress: "8.8.8.8")
        XCTAssertNil(WebGetTaskDelegate.connectedAddressRefusal([publicHop]))
        // A rebind on any hop (e.g. after a redirect) is refused.
        XCTAssertNotNil(WebGetTaskDelegate.connectedAddressRefusal([
            publicHop, Hop(isNetworkLoad: true, isProxy: false, remoteAddress: "192.168.0.10"),
        ]))
        // Fail closed when we cannot tell where we connected.
        XCTAssertNotNil(WebGetTaskDelegate.connectedAddressRefusal([]))
        XCTAssertNotNil(WebGetTaskDelegate.connectedAddressRefusal([
            Hop(isNetworkLoad: true, isProxy: false, remoteAddress: nil),
        ]))
        XCTAssertNotNil(WebGetTaskDelegate.connectedAddressRefusal([
            Hop(isNetworkLoad: false, isProxy: false, remoteAddress: nil),
        ]))
        // Proxied hops carry the proxy's address; skipped, not refused.
        XCTAssertNil(WebGetTaskDelegate.connectedAddressRefusal([
            Hop(isNetworkLoad: true, isProxy: true, remoteAddress: "127.0.0.1"),
        ]))
    }

    func testRedirectHopsResolveAndCap() {
        let resolve = resolver([
            "public.example": [.v4(0x0808_0808)],
            "evil.example": [.v4(0xA9FE_A9FE)],
        ])
        let delegate = WebGetTaskDelegate(resolve: resolve, allowPrivate: false)
        XCTAssertNil(delegate.redirectRefusal(to: url("https://public.example/a")))
        XCTAssertNotNil(delegate.redirectRefusal(to: url("https://evil.example/")))
        XCTAssertNotNil(delegate.redirectRefusal(to: url("file:///etc/passwd")))
        for _ in 0..<2 { XCTAssertNil(delegate.redirectRefusal(to: url("https://public.example/b"))) }
        XCTAssertNotNil(delegate.redirectRefusal(to: url("https://public.example/c")),
                        "6th hop exceeds the cap")

        let lan = WebGetTaskDelegate(resolve: resolve, allowPrivate: true)
        XCTAssertNil(lan.redirectRefusal(to: url("https://evil.example/")))
        XCTAssertNotNil(lan.redirectRefusal(to: url("ftp://evil.example/")))
    }

    func testRequestRefusesRebindingNameBeforeConnecting() async {
        let resolve = resolver(["rebind.example": [.v4(0x7F00_0001)]])
        do {
            _ = try await WebGet.request("http://rebind.example/", resolve: resolve, allowPrivate: false)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("loopback"), "\(error)")
        }
    }

    func testEscapeHatchReadsEnv() {
        XCTAssertTrue(HostPolicy.allowsPrivateURLs(env: ["APPLE_TASKS_ALLOW_PRIVATE_URLS": "1"]))
        XCTAssertFalse(HostPolicy.allowsPrivateURLs(env: [:]))
        XCTAssertFalse(HostPolicy.allowsPrivateURLs(env: ["APPLE_TASKS_ALLOW_PRIVATE_URLS": "0"]))
    }
}
