import XCTest
@testable import apple_tasks

/// tools/install.sh and tools/rollback.sh against a temp BINDIR with fake
/// binaries (#69). Signing and git refs are switched off.
final class InstallScriptTests: XCTestCase {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    var root: URL!
    var bin: URL { root.appendingPathComponent("bin") }
    var config: URL { root.appendingPathComponent("config") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A release dir whose apple-tasks reports `commit` and whose
    /// `dispatch-status` exits `statusExit`.
    func release(_ commit: String, statusExit: Int = 0) throws -> URL {
        let dir = root.appendingPathComponent("release-\(commit)-\(statusExit)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = """
        #!/bin/sh
        case "$1" in
          --version) echo "0.1.0 (commit \(commit))" ;;
          dispatch-status) exit \(statusExit) ;;
        esac
        """
        for (name, body) in [("apple-tasks", main), ("apple-tasks-private", "#!/bin/sh\necho helper-\(commit)\n")] {
            let url = dir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    @discardableResult
    func run(_ script: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repo.appendingPathComponent("tools/\(script)").path] + args
        var env = ProcessInfo.processInfo.environment
        env["INSTALL_SIGN"] = "/usr/bin/true"
        env["INSTALL_GIT_REFS"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func install(_ release: URL) throws -> (status: Int32, output: String) {
        try run("install.sh", [release.path, bin.path, config.path])
    }

    func installed(_ name: String = "apple-tasks") throws -> String {
        try String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)
    }

    func log() -> [String] {
        ((try? String(contentsOf: config.appendingPathComponent("installs.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func testFirstInstallHasNoPreviousSecondKeepsIt() throws {
        XCTAssertEqual(try install(release("aaa")).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("apple-tasks.prev").path))
        XCTAssertEqual(try install(release("bbb")).status, 0)
        XCTAssertTrue(try installed().contains("commit bbb"))
        XCTAssertTrue(try installed("apple-tasks.prev").contains("commit aaa"))
        XCTAssertTrue(try installed("apple-tasks-private.prev").contains("helper-aaa"))
        XCTAssertEqual(log().count, 2)
        XCTAssertTrue(log()[1].contains("\tbbb\taaa\t"))
        XCTAssertTrue(log()[1].hasSuffix("\tinstalled"))
    }

    func testReinstallingTheSameCommitKeepsTheRealPrevious() throws {
        try install(release("aaa"))
        try install(release("bbb"))
        XCTAssertEqual(try install(release("bbb")).status, 0)
        XCTAssertTrue(try installed("apple-tasks.prev").contains("commit aaa"))
        XCTAssertTrue(log().last?.hasSuffix("\treinstalled") ?? false)
    }

    func testFailedSmokeCheckRestoresThePreviousBuild() throws {
        try install(release("aaa"))
        let result = try install(release("bad", statusExit: 1))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("smoke check failed"))
        XCTAssertTrue(try installed().contains("commit aaa"))
        XCTAssertTrue(try installed("apple-tasks-private").contains("helper-aaa"))
        XCTAssertTrue(log().last?.contains("rolled back: dispatch-status failed") ?? false)
    }

    func testRollbackSwapsAndRunningTwiceReturns() throws {
        XCTAssertNotEqual(try run("rollback.sh", [bin.path, config.path]).status, 0, "nothing to roll back to")
        try install(release("aaa"))
        try install(release("bbb"))
        XCTAssertEqual(try run("rollback.sh", [bin.path, config.path]).status, 0)
        XCTAssertTrue(try installed().contains("commit aaa"))
        XCTAssertTrue(try installed("apple-tasks.prev").contains("commit bbb"))
        XCTAssertTrue(try installed("apple-tasks-private").contains("helper-aaa"))
        XCTAssertTrue(log().last?.hasSuffix("\trollback") ?? false)
        try run("rollback.sh", [bin.path, config.path])
        XCTAssertTrue(try installed().contains("commit bbb"))
    }

    func testRecentInstallsReadsTheLogTail() throws {
        for commit in ["a1", "a2", "a3"] { try install(release(commit)) }
        let lines = Doctor.recentInstalls(log: config.appendingPathComponent("installs.log"), limit: 2)
        XCTAssertEqual(lines?.count, 2)
        XCTAssertTrue(lines?.last?.contains("\ta3\ta2\t") ?? false)
        XCTAssertNil(Doctor.recentInstalls(log: root.appendingPathComponent("missing.log")))
    }
}
