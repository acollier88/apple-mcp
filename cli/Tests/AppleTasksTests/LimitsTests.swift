import XCTest
@testable import apple_tasks

final class LimitsTests: XCTestCase {
    func tempDB() throws -> (AuditDB, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (AuditDB(url: dir.appendingPathComponent("t.db")), dir)
    }

    @discardableResult
    func claim(_ db: AuditDB, agent: String, origin: String?, status: String = "succeeded") throws -> Int64 {
        guard case .claimed(let id) = db.claimDispatch(
            taskId: UUID().uuidString, agent: agent, command: "echo", cwd: nil) else {
            throw XCTSkip("claim failed")
        }
        if let origin { db.setOrigin(id: id, origin: origin) }
        if status != "running" { db.finishDispatch(id: id, status: status, exitCode: 0) }
        return id
    }

    func testOriginComesFromTheCreatingAuditRow() {
        XCTAssertEqual(Limits.origin(tags: [], creation: nil), "human")
        XCTAssertEqual(Limits.origin(tags: ["heal", "auto"], creation: nil), "doctor")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("launchd", "doctor-heal")), "doctor")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("andrew", "sync-github")), "github")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("andrew", "proposal-accept")), "human")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("andrew", "add")), "human")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("mcp", "add")), "mcp")
        XCTAssertEqual(Limits.origin(tags: [], creation: ("Agent:Cursor", "add-batch")), "agent:cursor")
    }

    func testCapsHoldOnlyWhenReached() {
        let limits = DispatchLimits(maxPerDay: 5, maxPerLanePerDay: ["claude": 2], maxAutomatedPerDay: 1)
        XCTAssertNil(Limits.taskHit(limits: limits, total: 4, automated: 0, origin: "human"))
        XCTAssertEqual(Limits.taskHit(limits: limits, total: 5, automated: 0, origin: "human"), .total(cap: 5))
        XCTAssertNil(Limits.taskHit(limits: limits, total: 2, automated: 1, origin: "human"),
                     "the automated cap does not hold human tasks")
        XCTAssertEqual(Limits.taskHit(limits: limits, total: 2, automated: 1, origin: "doctor"), .automated(cap: 1))
        XCTAssertEqual(Limits.laneHit(limits: limits, lane: "claude", count: 2), .lane("claude", cap: 2))
        XCTAssertNil(Limits.laneHit(limits: limits, lane: "cursor", count: 99))
        XCTAssertNil(Limits.taskHit(limits: DispatchLimits(maxPerDay: 0), total: 100, automated: 0, origin: "human"),
                     "0 means no cap")
        XCTAssertTrue(Limits.Hit.lane("claude", cap: 2).reason.hasPrefix("gated:"))
    }

    func testAlertsOncePerLimitPerDay() {
        let first = Limits.newAlerts([.total(cap: 5), .lane("claude", cap: 2)], stored: nil, day: "2026-11-18")
        XCTAssertEqual(first.fresh.count, 2)
        let again = Limits.newAlerts([.total(cap: 5)], stored: first.record, day: "2026-11-18")
        XCTAssertTrue(again.fresh.isEmpty)
        XCTAssertEqual(again.record, first.record)
        let tomorrow = Limits.newAlerts([.total(cap: 5)], stored: first.record, day: "2026-11-19")
        XCTAssertEqual(tomorrow.fresh, [.total(cap: 5)])
    }

    func testCountsSkipAbortedAndSplitAutomated() throws {
        let (db, _) = try tempDB()
        try claim(db, agent: "claude", origin: "human")
        try claim(db, agent: "claude", origin: "doctor")
        try claim(db, agent: "cursor", origin: nil)
        try claim(db, agent: "cursor", origin: "mcp", status: "aborted")
        let since = Limits.dayStart()
        XCTAssertEqual(db.dispatchCount(since: since), 3)
        XCTAssertEqual(db.dispatchCount(since: since, agent: "claude"), 2)
        XCTAssertEqual(db.dispatchCount(since: since, automatedOnly: true), 1)
        let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400 * 2))
        XCTAssertEqual(db.dispatchCount(since: tomorrow), 0)

        let limits = DispatchLimits(maxPerDay: 3, maxPerLanePerDay: ["claude": 2, "cursor": 5], maxAutomatedPerDay: 2)
        let status = Limits.status(limits: limits, lanes: ["claude", "cursor"], db: db)
        XCTAssertEqual(status.total, 3)
        XCTAssertEqual(status.automated, 1)
        XCTAssertEqual(status.perLane, ["claude": 2, "cursor": 1])
        XCTAssertEqual(status.reached, ["limit:total", "limit:lane:claude"])
        XCTAssertNil(status.stoppedAt)
    }

    func testCreationRecordIsTheFirstSuccessfulCreate() throws {
        let (db, _) = try tempDB()
        db.record(command: "update", taskId: "T1", detail: "x")
        db.record(command: "add", taskId: "T1", detail: "x", result: "refused", error: "nope")
        db.record(command: "add", taskId: "T1", detail: "x")
        XCTAssertEqual(db.creationRecord(taskId: "T1")?.command, "add")
        XCTAssertNil(db.creationRecord(taskId: "T2"))
    }

    func testStopStateClearsOnResume() throws {
        let (db, _) = try tempDB()
        _ = db.setState(Limits.stoppedKey, "2026-11-18T22:00:00Z")
        _ = try Dispatch.applyPause(db: db, until: Date().addingTimeInterval(Limits.stopPause), reason: "stopped")
        XCTAssertNotNil(Limits.stopped(db: db))
        XCTAssertNotNil(Dispatch.resolvedPause(db: db))
        _ = Dispatch.applyResume(db: db)
        XCTAssertNil(Limits.stopped(db: db))
        XCTAssertNil(Dispatch.resolvedPause(db: db))
    }

    func testResumeIsRefusedToAgents() {
        XCTAssertNotNil(CallerGuard.reviewRefusal(command: "dispatch-resume", caller: "agent:cursor"))
        XCTAssertNil(CallerGuard.reviewRefusal(command: "dispatch-resume", caller: "mcp"))
    }
}
