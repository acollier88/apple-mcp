import Foundation
import XCTest
@testable import apple_tasks

final class AuditDBTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    private func openDB() -> AuditDB {
        AuditDB(url: tempDir.appendingPathComponent("test.db"))
    }

    func testOpensTempDatabase() {
        XCTAssertTrue(openDB().isAvailable)
    }

    func testClaimDispatchHeldThenReclaimAfterSuccess() {
        let db = openDB()
        let first = db.claimDispatch(taskId: "task-1", agent: "cursor", command: "echo", cwd: nil)
        guard case .claimed(let id) = first else {
            return XCTFail("expected claimed, got \(first)")
        }
        let second = db.claimDispatch(taskId: "task-1", agent: "cursor", command: "echo", cwd: nil)
        XCTAssertEqual(second, .held)

        XCTAssertTrue(db.finishDispatch(id: id, status: "succeeded", exitCode: 0))
        let third = db.claimDispatch(taskId: "task-1", agent: "cursor", command: "echo", cwd: nil)
        guard case .claimed = third else {
            return XCTFail("expected claimed after success, got \(third)")
        }
    }

    func testDirectoryPathIsUnavailable() throws {
        let dir = tempDir.appendingPathComponent("not-a-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = AuditDB(url: dir)
        XCTAssertFalse(db.isAvailable)
        XCTAssertEqual(
            db.claimDispatch(taskId: "t", agent: "a", command: "c", cwd: nil),
            .unavailable
        )
    }

    func testReapStaleFlipsRunningToTimeout() {
        let db = openDB()
        let claim = db.claimDispatch(taskId: "stale", agent: "cursor", command: "sleep", cwd: nil)
        guard case .claimed(let id) = claim else {
            return XCTFail("expected claimed, got \(claim)")
        }
        // reapStale takes an ISO-8601 string and uses started_at < cutoff.
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5))
        let reaped = db.reapStale(before: cutoff)
        XCTAssertEqual(reaped.count, 1)
        XCTAssertEqual(reaped.first?.taskId, "stale")
        // NOTE: returned rows are the pre-update snapshot (status still "running").
        XCTAssertEqual(reaped.first?.status, "running")
        XCTAssertEqual(db.dispatchRow(id: id)?.status, "timeout")
    }

    func testFailedAttemptsCountsFailedAndTimeout() {
        let db = openDB()
        let first = db.claimDispatch(taskId: "retries", agent: "cursor", command: "x", cwd: nil)
        guard case .claimed(let id1) = first else {
            return XCTFail("expected claimed, got \(first)")
        }
        XCTAssertTrue(db.finishDispatch(id: id1, status: "failed", exitCode: 1))

        let second = db.claimDispatch(taskId: "retries", agent: "cursor", command: "x", cwd: nil)
        guard case .claimed(let id2) = second else {
            return XCTFail("expected claimed, got \(second)")
        }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5))
        _ = db.reapStale(before: cutoff)
        XCTAssertEqual(db.dispatchRow(id: id2)?.status, "timeout")

        let attempts = db.failedAttempts(taskId: "retries")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotNil(attempts.lastFinishedAt)
    }

    func testGetStateSetStateUpserts() {
        let db = openDB()
        XCTAssertNil(db.getState("watermark"))
        XCTAssertTrue(db.setState("watermark", "one"))
        XCTAssertEqual(db.getState("watermark"), "one")
        XCTAssertTrue(db.setState("watermark", "two"))
        XCTAssertEqual(db.getState("watermark"), "two")
    }

    func testDispatchRowReturnsClaim() {
        let db = openDB()
        let claim = db.claimDispatch(taskId: "row", agent: "claude", command: "ls", cwd: "/tmp")
        guard case .claimed(let id) = claim else {
            return XCTFail("expected claimed, got \(claim)")
        }
        let row = db.dispatchRow(id: id)
        XCTAssertEqual(row?.taskId, "row")
        XCTAssertEqual(row?.agent, "claude")
        XCTAssertEqual(row?.command, "ls")
        XCTAssertEqual(row?.status, "running")
    }
}
