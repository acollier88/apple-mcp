import AppleTasksServerCore
import XCTest

/// #34: `AppleTasksCLI.run` must drain pipes while the child runs. Before
/// the fix, any response over ~64 KB blocked until the timeout (HTTP 502).
final class CLIRunTests: XCTestCase {
    private let bigCount = 300_000

    func testLargeStdoutCompletesWithFullOutput() throws {
        let start = Date()
        let out = try AppleTasksCLI.run(
            ["-c", "head -c \(bigCount) /dev/zero | tr '\\0' a"],
            timeout: 20, executable: "/bin/sh")
        XCTAssertEqual(out.utf8.count, bigCount)
        XCTAssertTrue(out.allSatisfy { $0 == "a" })
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testHeavyStderrDoesNotDeadlockAndSurfacesInFailure() throws {
        let start = Date()
        let script = "head -c \(bigCount) /dev/zero | tr '\\0' e >&2; "
            + "head -c \(bigCount) /dev/zero | tr '\\0' o; exit 4"
        XCTAssertThrowsError(try AppleTasksCLI.run(["-c", script], timeout: 20, executable: "/bin/sh")) { error in
            guard case CLIError.failed(let code, let stderr) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(code, 4)
            XCTAssertEqual(stderr.utf8.count, self.bigCount)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutKillsSleepingChild() {
        let start = Date()
        XCTAssertThrowsError(try AppleTasksCLI.run(["-c", "exec sleep 30"], timeout: 0.5,
                                                   executable: "/bin/sh")) { error in
            guard case CLIError.timeout = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testTimeoutEscalatesWhenTermIgnored() {
        let start = Date()
        XCTAssertThrowsError(try AppleTasksCLI.run(["-c", "trap '' TERM; while :; do :; done"],
                                                   timeout: 0.5, executable: "/bin/sh")) { error in
            guard case CLIError.timeout = error else { return XCTFail("unexpected \(error)") }
        }
        // 0.5 s deadline + 2 s SIGTERM grace, then SIGKILL.
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testGrandchildHoldingPipeDoesNotExtendRequest() throws {
        let start = Date()
        let out = try AppleTasksCLI.run(["-c", "sleep 30 & echo started"], timeout: 20,
                                        executable: "/bin/sh")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "started")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testCallerEnvironmentIsSet() throws {
        let out = try AppleTasksCLI.run(["-c", "printf %s \"$APPLE_TASKS_CALLER\""],
                                        timeout: 5, executable: "/bin/sh")
        XCTAssertEqual(out, "apple-tasks-server")
    }
}
