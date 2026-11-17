import XCTest
@testable import apple_tasks

/// #34: a child that writes more than the pipe buffer (~64 KB) must not
/// deadlock the parent, and a hung child must be killed at the deadline.
final class ProcessRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let bigCount = 300_000

    func testLargeStdoutCompletesWithFullOutput() throws {
        let start = Date()
        let result = try ProcessRunner.run(
            sh, ["-c", "head -c \(bigCount) /dev/zero | tr '\\0' a"], timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, bigCount)
        XCTAssertTrue(result.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testHeavyStderrDoesNotDeadlock() throws {
        let start = Date()
        // Fill stderr first, then stdout: sequential readers block on one
        // pipe while the child blocks writing the other.
        let script = "head -c \(bigCount) /dev/zero | tr '\\0' e >&2; "
            + "head -c \(bigCount) /dev/zero | tr '\\0' o; exit 3"
        let result = try ProcessRunner.run(sh, ["-c", script], timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stderr.count, bigCount)
        XCTAssertEqual(result.stdout.count, bigCount)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutKillsSleepingChild() throws {
        let start = Date()
        let result = try ProcessRunner.run(sh, ["-c", "exec sleep 30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(elapsed, 5)
    }

    func testTimeoutEscalatesToSIGKILLWhenTermIgnored() throws {
        let start = Date()
        let result = try ProcessRunner.run(
            sh, ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.5, killGrace: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testGrandchildHoldingPipeDoesNotExtendRun() throws {
        let start = Date()
        let result = try ProcessRunner.run(sh, ["-c", "sleep 30 & echo started"], timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "started")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testLargeStdinRoundTrips() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: bigCount)
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), stdin: payload, timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, payload)
    }

    func testChildIgnoringStdinDoesNotSIGPIPEParent() throws {
        let payload = Data(repeating: 0, count: 1_000_000)
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), stdin: payload, timeout: 20)
        XCTAssertEqual(result.status, 0)
    }

    func testDefaultStdinIsNullDevice() throws {
        // `cat` with no stdin payload must see EOF immediately, not a terminal.
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), timeout: 5)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 0)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try ProcessRunner.run(
            URL(fileURLWithPath: "/nonexistent/apple-tasks-test"), timeout: 1))
    }

    /// The real call site from the issue: JXA output over the pipe buffer.
    /// Pure JS needs no Automation permission.
    func testRunJXALargeOutput() throws {
        let start = Date()
        let out = try OSA.runJXA("function run(argv) { return 'n'.repeat(Number(argv[0])); }",
                                 args: [String(bigCount)], timeout: 60)
        XCTAssertEqual(out.count, bigCount)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testRunJXATimeoutThrows() {
        XCTAssertThrowsError(try OSA.runJXA(
            "function run() { delay(30); return 'late'; }", args: [], timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
    }
}
