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

    func testEscapeHatchReadsEnv() {
        XCTAssertTrue(HostPolicy.allowsPrivateURLs(env: ["APPLE_TASKS_ALLOW_PRIVATE_URLS": "1"]))
        XCTAssertFalse(HostPolicy.allowsPrivateURLs(env: [:]))
        XCTAssertFalse(HostPolicy.allowsPrivateURLs(env: ["APPLE_TASKS_ALLOW_PRIVATE_URLS": "0"]))
    }
}
