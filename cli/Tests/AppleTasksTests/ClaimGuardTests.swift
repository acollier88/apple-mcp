import XCTest
@testable import apple_tasks

final class ClaimGuardTests: XCTestCase {
    func testNilLastDoesNotBlock() {
        XCTAssertNil(Dispatch.unchangedSinceSuccess(current: "abc", last: nil))
    }

    func testLastWithoutFingerprintDoesNotBlock() {
        XCTAssertNil(Dispatch.unchangedSinceSuccess(current: "abc", last: row(id: 7, fingerprint: nil)))
    }

    func testEqualFingerprintAfterWalkAwayReturnsLedgerId() {
        XCTAssertEqual(Dispatch.unchangedSinceSuccess(current: "abc", last: row(id: 42, fingerprint: "abc")), 42)
    }

    func testDifferentFingerprintDoesNotBlock() {
        XCTAssertNil(Dispatch.unchangedSinceSuccess(current: "abc", last: row(id: 42, fingerprint: "xyz")))
    }

    /// The agent completed the task (recurring: due rolled during the run, so
    /// the stored fingerprint IS the next occurrence). Must never block.
    func testCompletedRunNeverBlocksEvenWhenUnchanged() {
        XCTAssertNil(Dispatch.unchangedSinceSuccess(
            current: "abc", last: row(id: 42, fingerprint: "abc", verification: "completed")))
        XCTAssertNil(Dispatch.unchangedSinceSuccess(
            current: "abc", last: row(id: 42, fingerprint: "abc", verification: "open-untagged")))
        XCTAssertNil(Dispatch.unchangedSinceSuccess(
            current: "abc", last: row(id: 42, fingerprint: "abc", verification: nil)))
    }

    func testClaimGuardParsesAndDefaultsToNil() throws {
        let withValue = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{},"claimGuard":"modified"}"#.utf8))
        XCTAssertEqual(withValue.claimGuard, "modified")

        let running = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{},"claimGuard":"running"}"#.utf8))
        XCTAssertEqual(running.claimGuard, "running")

        let omitted = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{}}"#.utf8))
        XCTAssertNil(omitted.claimGuard)
    }

    private func row(id: Int, fingerprint: String?, verification: String? = "open-claimed") -> AuditDB.DispatchRow {
        AuditDB.DispatchRow(
            id: id, taskId: "t", agent: "echo", command: "echo", cwd: nil,
            startedAt: "2026-01-01T00:00:00Z", finishedAt: "2026-01-01T00:00:01Z",
            status: "succeeded", exitCode: 0, runLogPath: nil, worktree: nil,
            summary: nil, pid: nil, taskFingerprint: fingerprint,
            taskModifiedAt: nil, verification: verification, reviewedAt: nil)
    }
}
