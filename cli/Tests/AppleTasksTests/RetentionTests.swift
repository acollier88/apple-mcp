import SQLite3
import XCTest
@testable import apple_tasks

final class RetentionTests: XCTestCase {
    var dir: URL!
    var runs: URL!
    var dbURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        runs = dir.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("t.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A finished run `daysAgo` old with a log + prompt file in `runs/`.
    @discardableResult
    func run(_ db: AuditDB, status: String, daysAgo: Double, worktree: String? = nil,
             summary: String? = "agent said things") throws -> (id: Int64, log: String, prompt: String) {
        guard case .claimed(let id) = db.claimDispatch(
            taskId: UUID().uuidString, agent: "cursor", command: "echo", cwd: nil) else {
            throw XCTSkip("claim failed")
        }
        let log = runs.appendingPathComponent("\(id).log").path
        let prompt = runs.appendingPathComponent("\(id).prompt").path
        FileManager.default.createFile(atPath: log, contents: Data("log".utf8))
        FileManager.default.createFile(atPath: prompt, contents: Data("prompt".utf8))
        db.setDispatchPaths(id: id, runLogPath: log, worktree: worktree)
        XCTAssertTrue(db.finishDispatch(id: id, status: status, exitCode: status == "succeeded" ? 0 : 1,
                                        summary: summary))
        backdate(id: id, daysAgo: daysAgo)
        return (id, log, prompt)
    }

    func backdate(id: Int64?, daysAgo: Double) {
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 86_400))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)
        XCTAssertEqual(sqlite3_exec(
            handle, id.map { "UPDATE dispatches SET finished_at = '\(ts)', started_at = '\(ts)' WHERE id = \($0)" }
                ?? "UPDATE audit SET ts = '\(ts)'", nil, nil, nil), SQLITE_OK)
    }

    func testPolicyDefaultsAndZeroKeepsForever() {
        XCTAssertEqual(Retention.Policy(nil), .defaults)
        let custom = Retention.Policy(RetentionConfig(runLogDays: 0, failedRunLogDays: -3, ledgerTextDays: 7))
        XCTAssertEqual(custom, Retention.Policy(runLogDays: 0, failedRunLogDays: 0, ledgerTextDays: 7))
        XCTAssertNil(Retention.cutoff(days: 0, now: Date()))
    }

    func testOldLogsGoFailedOnesLastLongerPendingReviewStays() throws {
        let db = AuditDB(url: dbURL)
        let oldOK = try run(db, status: "succeeded", daysAgo: 40)
        let freshOK = try run(db, status: "succeeded", daysAgo: 5)
        let oldFail = try run(db, status: "failed", daysAgo: 40)
        let ancientFail = try run(db, status: "timeout", daysAgo: 100)
        let pending = try run(db, status: "succeeded", daysAgo: 60, worktree: dir.appendingPathComponent("wt").path)

        let result = Retention.prune(policy: .defaults, runs: runs, db: db)
        XCTAssertEqual(result.runLogsRemoved, 2)
        XCTAssertEqual(result.promptFilesRemoved, 2)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: oldOK.log))
        XCTAssertFalse(fm.fileExists(atPath: oldOK.prompt))
        XCTAssertFalse(fm.fileExists(atPath: ancientFail.log))
        for kept in [freshOK, oldFail, pending] {
            XCTAssertTrue(fm.fileExists(atPath: kept.log))
            XCTAssertTrue(fm.fileExists(atPath: kept.prompt))
        }
        XCTAssertNil(db.dispatchRow(id: oldOK.id)?.runLogPath)
        XCTAssertNotNil(db.dispatchRow(id: oldOK.id), "the ledger row itself is kept")
        XCTAssertEqual(db.dispatchRow(id: pending.id)?.runLogPath, pending.log)
    }

    func testLogsOutsideRunsAreNeverDeleted() throws {
        let db = AuditDB(url: dbURL)
        let row = try run(db, status: "succeeded", daysAgo: 40)
        let outside = dir.appendingPathComponent("elsewhere.log").path
        FileManager.default.createFile(atPath: outside, contents: Data("keep".utf8))
        db.setDispatchPaths(id: row.id, runLogPath: outside, worktree: nil)
        let result = Retention.prune(policy: .defaults, runs: runs, db: db)
        XCTAssertEqual(result.runLogsRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertFalse(Retention.isInside(runs.appendingPathComponent("../x.log").path, directory: runs))
        XCTAssertTrue(Retention.isInside(runs.appendingPathComponent("3.log").path, directory: runs))
    }

    func testOldLedgerTextIsClearedRowsKept() throws {
        let db = AuditDB(url: dbURL)
        db.record(command: "add", detail: "secret-ish title")
        let old = try run(db, status: "succeeded", daysAgo: 200)
        let fresh = try run(db, status: "succeeded", daysAgo: 1)
        backdate(id: nil, daysAgo: 200)
        db.record(command: "add", detail: "recent title")
        let result = Retention.prune(
            policy: Retention.Policy(runLogDays: 0, failedRunLogDays: 0, ledgerTextDays: 180), runs: runs, db: db)
        XCTAssertGreaterThanOrEqual(result.textCleared, 2)
        XCTAssertNil(db.dispatchRow(id: old.id)?.summary)
        XCTAssertEqual(db.dispatchRow(id: fresh.id)?.summary, "agent said things")
        XCTAssertEqual(db.auditRows(since: nil, taskId: nil, caller: nil, limit: 50).filter { $0.detail == "recent title" }.count, 1)
        XCTAssertTrue(db.auditRows(since: nil, taskId: nil, caller: nil, limit: 50).allSatisfy { $0.detail != "secret-ish title" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.log), "0 days keeps logs forever")
    }

    func testCompactsAtMostDailyAndReportsStatus() throws {
        let db = AuditDB(url: dbURL)
        try run(db, status: "succeeded", daysAgo: 3)
        let now = Date()
        XCTAssertTrue(Retention.prune(policy: .defaults, runs: runs, db: db, now: now).compacted)
        XCTAssertFalse(Retention.prune(policy: .defaults, runs: runs, db: db,
                                       now: now.addingTimeInterval(3600)).compacted)
        XCTAssertTrue(Retention.prune(policy: .defaults, runs: runs, db: db,
                                      now: now.addingTimeInterval(90_000)).compacted)
        let status = Retention.status(policy: .defaults, runs: runs, ledger: dbURL, db: db)
        XCTAssertEqual(status.runsFiles, 2)
        XCTAssertGreaterThan(status.runsBytes, 0)
        XCTAssertGreaterThan(status.ledgerBytes, 0)
        XCTAssertNotNil(status.oldestRetainedRun)
        XCTAssertNotNil(status.lastCompacted)
    }
}
