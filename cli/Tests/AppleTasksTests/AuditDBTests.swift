import Foundation
import SQLite3
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
        let db = openDB()
        XCTAssertTrue(db.isAvailable)
        XCTAssertEqual(db.schemaVersion, AuditDB.schemaVersion)
    }

    /// A pre-2026-09 database (user_version 0, no pid/task_modified_at, the
    /// old ad-hoc columns present) migrates in place without losing rows.
    func testMigratesVersionZeroDatabase() throws {
        let url = tempDir.appendingPathComponent("v0.db")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        let legacy = """
        CREATE TABLE dispatches (
            id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, agent TEXT NOT NULL,
            command TEXT NOT NULL, cwd TEXT, started_at TEXT NOT NULL, finished_at TEXT,
            status TEXT NOT NULL, exit_code INTEGER, run_log_path TEXT, worktree TEXT, summary TEXT);
        INSERT INTO dispatches (task_id, agent, command, started_at, status)
            VALUES ('legacy', 'cursor', 'echo', '2026-08-01T00:00:00Z', 'succeeded');
        """
        XCTAssertEqual(sqlite3_exec(raw, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = AuditDB(url: url)
        XCTAssertTrue(db.isAvailable)
        XCTAssertEqual(db.schemaVersion, AuditDB.schemaVersion)
        let row = db.dispatchRow(id: 1)
        XCTAssertEqual(row?.taskId, "legacy")
        XCTAssertNil(row?.pid)
        // New column is writable after migration.
        XCTAssertTrue(db.setDispatchPid(id: 1, pid: 4242))
        XCTAssertEqual(db.dispatchRow(id: 1)?.pid, 4242)
        // Reopening does not re-run the migration or fail on existing columns.
        let again = AuditDB(url: url)
        XCTAssertEqual(again.schemaVersion, AuditDB.schemaVersion)
        XCTAssertEqual(again.dispatchRow(id: 1)?.pid, 4242)
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
