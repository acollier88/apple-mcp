import XCTest
@testable import apple_tasks

/// #33: build stamp parsing and doctor's commit-vs-HEAD comparison.
final class DeploymentStatusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/cli"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try git("init", "-q")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - BuildInfo

    func testVersionStringParsing() {
        XCTAssertEqual(BuildInfo.commit(fromVersionOutput: "0.1.0 (commit abc123def456)\n"), "abc123def456")
        XCTAssertEqual(BuildInfo.commit(fromVersionOutput: "0.1.0 (commit abc123-dirty)"), "abc123-dirty")
        XCTAssertNil(BuildInfo.commit(fromVersionOutput: "0.1.0 (commit unknown)"))
        XCTAssertNil(BuildInfo.commit(fromVersionOutput: "0.1.0\n"), "pre-#33 binaries print a bare version")
    }

    func testStampParsing() {
        let fields = BuildInfo.parse("commit=abc123\nsource=/Users/x/apple-mcp\n")
        XCTAssertEqual(fields["commit"], "abc123")
        XCTAssertEqual(fields["source"], "/Users/x/apple-mcp")
    }

    func testUnstampedTestBuildReportsUnknown() {
        // `swift test` links no __at_build section.
        XCTAssertEqual(BuildInfo.commit, "unknown")
        XCTAssertTrue(BuildInfo.versionString.hasSuffix("(commit unknown)"))
    }

    // MARK: - deploymentStatus

    func testMatchingCommitIsOK() throws {
        let a = try commit(file: "cli/a.swift", "1")
        let status = try status(binaryPrints: "0.1.0 (commit \(a))")
        XCTAssertEqual(status.comparison, "commit")
        XCTAssertEqual(status.launchdCommit, a)
        XCTAssertEqual(status.binaryMatchesHead, true)
        XCTAssertTrue(status.note.hasPrefix("ok"), status.note)
    }

    func testDocsOnlyCommitsSinceBuildStillMatch() throws {
        let a = try commit(file: "cli/a.swift", "1")
        _ = try commit(file: "README.md", "docs")
        let status = try status(binaryPrints: "0.1.0 (commit \(a))")
        XCTAssertEqual(status.binaryMatchesHead, true, status.note)
    }

    func testBehindHeadInCliIsFlagged() throws {
        let a = try commit(file: "cli/a.swift", "1")
        _ = try commit(file: "cli/a.swift", "2")
        let status = try status(binaryPrints: "0.1.0 (commit \(a))")
        XCTAssertEqual(status.binaryMatchesHead, false)
        XCTAssertTrue(status.note.contains("behind HEAD"), status.note)
    }

    func testBranchBuildIsFlagged() throws {
        _ = try commit(file: "cli/a.swift", "1")
        try git("checkout", "-q", "-b", "feature")
        let branch = try commit(file: "cli/a.swift", "feature")
        try git("checkout", "-q", "-")
        let status = try status(binaryPrints: "0.1.0 (commit \(branch))")
        XCTAssertEqual(status.binaryMatchesHead, false)
        XCTAssertTrue(status.note.contains("not in HEAD's history"), status.note)
    }

    func testDirtyBuildIsNotAMatch() throws {
        let a = try commit(file: "cli/a.swift", "1")
        let status = try status(binaryPrints: "0.1.0 (commit \(a)-dirty)")
        XCTAssertEqual(status.binaryMatchesHead, false)
        XCTAssertTrue(status.note.contains("uncommitted"), status.note)
    }

    func testUnknownCommitFallsBackToMtime() throws {
        _ = try commit(file: "cli/a.swift", "1")
        let status = try status(binaryPrints: "0.1.0")
        XCTAssertEqual(status.comparison, "mtime")
        XCTAssertNil(status.launchdCommit)
        XCTAssertNil(status.binaryMatchesHead)
        XCTAssertNotNil(status.binaryOlderThanCliCommit)
    }

    // MARK: - helpers

    private var repo: URL { root.appendingPathComponent("repo") }

    /// A stand-in "installed binary" outside the checkout that only answers --version.
    private func status(binaryPrints version: String) throws -> DoctorOut.DeploymentStatus {
        let bin = root.appendingPathComponent("bin/apple-tasks")
        try "#!/bin/sh\necho '\(version)'\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return Doctor.deploymentStatus(binary: bin.path, sourceTreeHint: repo.path)
    }

    @discardableResult
    private func commit(file: String, _ contents: String) throws -> String {
        try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", "c")
        return try git("rev-parse", "--short=12", "HEAD")
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false",
             "-c", "init.defaultBranch=main", "-C", repo.path] + args,
            timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: result.stderrString])
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
