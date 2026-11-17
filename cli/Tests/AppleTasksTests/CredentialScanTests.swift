import XCTest
@testable import apple_tasks

final class CredentialScanTests: XCTestCase {
    func testFlagsWellKnownCredentialPaths() {
        let log = """
        $ cat ~/.ssh/id_ed25519
        reading /Users/me/.config/gh/hosts.yml
        open ~/.aws/credentials and ~/.netrc
        ls ~/Library/Keychains/login.keychain-db
        security find-generic-password -s foo -w
        source ~/.config/apple-tasks/launchd.env
        cat ~/.hermes/.env
        """
        XCTAssertEqual(CredentialScan.matches(in: log),
                       [".ssh/", "gh/hosts.yml", ".aws/credentials", ".netrc", "Keychains/",
                        "security-find-password", "launchd.env", ".env"])
    }

    func testDotenvBoundaries() {
        XCTAssertEqual(CredentialScan.matches(in: "cat .env"), [".env"])
        XCTAssertEqual(CredentialScan.matches(in: "cp ./.env.local /tmp"), [".env"])
        XCTAssertEqual(CredentialScan.matches(in: "read \".env\""), [".env"])
        XCTAssertEqual(CredentialScan.matches(in: "process.env.HOME"), [])
        XCTAssertEqual(CredentialScan.matches(in: "direnv allow .envrc"), [])
        XCTAssertEqual(CredentialScan.matches(in: "source launchd.env"), ["launchd.env"])
    }

    func testCleanLogHasNoHits() {
        let log = "Edited Sources/App.swift\nRan swift test: 142 passed\ngh pr create --title x\n"
        XCTAssertEqual(CredentialScan.matches(in: log), [])
        XCTAssertNil(CredentialScan.summary([]))
        XCTAssertEqual(CredentialScan.summary([".ssh/", ".env"]), "cred-paths-in-log=.ssh/,.env")
    }

    func testHeaderIsNotScanned() {
        let text = "# dispatch #3 2026-01-01\n# task T: read ~/.ssh/config\n# agent -p <prompt omitted>\n\nall good\n"
        XCTAssertEqual(CredentialScan.matches(in: CredentialScan.stripHeader(text)), [])
        XCTAssertEqual(CredentialScan.stripHeader("no header\n~/.ssh/x"), "no header\n~/.ssh/x")
    }

    func testScanLogReadsBoundedHeadAndTail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("credscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("1.log")
        let filler = String(repeating: "x", count: 4096) + "\n"
        var body = "# dispatch #1\n# task T: ~/.netrc in title\n\nstart cat ~/.ssh/id_rsa\n"
        body += String(repeating: filler, count: 8)
        body += "middle ~/.aws/credentials\n"
        body += String(repeating: filler, count: 8)
        body += "end source launchd.env\n"
        try Data(body.utf8).write(to: url)
        // Window 16 KiB: head and tail are scanned, the middle is skipped.
        XCTAssertEqual(CredentialScan.scanLog(at: url.path, window: 16 * 1024), [".ssh/", "launchd.env"])
        // Small file: read whole; header still skipped.
        XCTAssertEqual(CredentialScan.scanLog(at: url.path, window: 1 << 20),
                       [".ssh/", ".aws/credentials", "launchd.env"])
        XCTAssertEqual(CredentialScan.scanLog(at: dir.appendingPathComponent("missing.log").path), [])
    }

    func testTrailerCarriesFlags() {
        let line = Dispatch.trailer(ledgerId: 9, status: "failed", exitCode: 1, branch: nil,
                                    repo: nil, logPath: "/r/9.log", seat: nil,
                                    credentialFlags: [".ssh/"])
        XCTAssertEqual(line, "[dispatch #9] failed exit=1 cred-paths-in-log=.ssh/ log=/r/9.log")
        XCTAssertEqual(Dispatch.trailer(ledgerId: 9, status: "failed", exitCode: 1, branch: nil,
                                        repo: nil, logPath: nil, seat: nil),
                       "[dispatch #9] failed exit=1")
    }
}
