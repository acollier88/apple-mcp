import XCTest
@testable import apple_tasks

final class DetectorsBatch1Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    func testWaitingCountsPassesForTheSameReasonOnly() {
        let pass1 = Diagnostics.nextWaiting(previous: [], reports: [
            ("A", "Fix it", "gated: login missing (agent login) — stays queued"),
            ("B", "Other", "dispatched"),
            ("C", "Capped", "gated: daily dispatch limit reached (5) — stays queued"),
        ], now: "t1")
        XCTAssertEqual(pass1.map(\.taskId), ["A"], "daily caps and dispatched tasks are not waiting")
        XCTAssertEqual(pass1.first?.reason, "gated: login missing (agent login)")
        let pass2 = Diagnostics.nextWaiting(previous: pass1, reports: [
            ("A", "Fix it", "gated: login missing (agent login) — stays queued"),
        ], now: "t2")
        XCTAssertEqual(pass2.first?.passes, 2)
        XCTAssertEqual(pass2.first?.since, "t1")
        let pass3 = Diagnostics.nextWaiting(previous: pass2, reports: [
            ("A", "Fix it", "queued: no available provider (auto pool empty) — stays queued"),
        ], now: "t3")
        XCTAssertEqual(pass3.first?.passes, 1, "a new reason restarts the count")
        XCTAssertTrue(Diagnostics.nextWaiting(previous: pass3, reports: [], now: "t4").isEmpty)
    }

    func testQueueStuckAndForeignClaims() {
        let waiting = [Diagnostics.WaitingTask(taskId: "A", title: "Fix it", reason: "gated: x", passes: 12, since: "t"),
                       Diagnostics.WaitingTask(taskId: "B", title: "New", reason: "gated: y", passes: 3, since: "t")]
        let stuck = Diagnostics.queueStuck(waiting, minPasses: 12)
        XCTAssertEqual(stuck.map(\.signature), ["queue-stuck:A"])
        XCTAssertFalse(stuck[0].evidence.contains("12"), "evidence stays stable as passes grow")

        let claims = [Diagnostics.ForeignClaim(taskId: "T", title: "Old", tag: "dispatched:otherbox", modified: days(5)),
                      Diagnostics.ForeignClaim(taskId: "U", title: "Fresh", tag: "dispatched:otherbox", modified: days(1))]
        let found = Diagnostics.foreignClaims(claims, now: now, days: 3)
        XCTAssertEqual(found.map(\.signature), ["foreign-claim:T"])
        XCTAssertEqual(found.first?.kind, .needsHuman)
    }

    func testLaneStreakIsConsecutiveFromNewest() {
        func run(_ id: Int, _ agent: String, _ status: String) -> Diagnostics.LaneRun {
            .init(id: id, agent: agent, status: status, cwd: nil, verification: nil)
        }
        let runs = [run(9, "claude", "failed"), run(8, "claude", "timeout"), run(7, "claude", "running"),
                    run(6, "claude", "failed"), run(5, "claude", "succeeded"),
                    run(4, "cursor", "failed"), run(3, "cursor", "succeeded"), run(2, "cursor", "failed")]
        let found = Diagnostics.laneStreaks(runs, streak: 3)
        XCTAssertEqual(found.map(\.signature), ["lane-failing:claude"])
        XCTAssertEqual(found.first?.kind, .healable)
        XCTAssertEqual(found.first?.evidence, "streak since ledger #6")
    }

    func testRepoUnverified() {
        func run(_ id: Int, _ cwd: String, _ v: String?) -> Diagnostics.LaneRun {
            .init(id: id, agent: "cursor", status: "succeeded", cwd: cwd, verification: v)
        }
        let runs = [run(5, "/r/app", "open-claimed"), run(4, "/r/app", "open-claimed"), run(3, "/r/app", "open-claimed"),
                    run(2, "/r/lib", "open-claimed"), run(1, "/r/lib", "completed")]
        let found = Diagnostics.repoUnverified(runs, streak: 3)
        XCTAssertEqual(found.map(\.signature), ["repo-unverified:app"])
        XCTAssertEqual(found.first?.kind, .proposable)
        XCTAssertEqual(found.first?.severity, "notice")
    }

    func testCadenceNeedsDistinctTasksAtASteadyInterval() {
        let weekly = (0..<4).map { i in
            Diagnostics.DispatchedTitle(taskId: "w\(i)", title: "Weekly  report", at: days(Double(28 - 7 * i)))
        }
        let sameTask = (0..<4).map { i in
            Diagnostics.DispatchedTitle(taskId: "r", title: "Recurring already", at: days(Double(4 - i)))
        }
        let irregular = [1.0, 2, 20].enumerated().map { i, d in
            Diagnostics.DispatchedTitle(taskId: "i\(i)", title: "Irregular", at: days(d))
        }
        let found = Diagnostics.cadence(weekly + sameTask + irregular, minRuns: 3)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].summary.contains("every 7 days"))
        XCTAssertTrue(found[0].signature.hasPrefix("cadence:"))
        XCTAssertEqual(found[0].kind, .proposable)
    }

    func testDevHygiene() {
        let repos = [Diagnostics.RepoHygiene(
            name: "app", mergedBranches: ["feature/x", "fix/y"], dirtyDays: 4,
            greenPRs: [.init(number: 7, title: "Old", url: "https://example.invalid/7", ageDays: 9),
                       .init(number: 8, title: "New", url: "https://example.invalid/8", ageDays: 2)])]
        let pending = [Diagnostics.PendingAge(ledgerId: 41, branch: "agent/cursor-41", repo: "/r/app", ageDays: 8),
                       Diagnostics.PendingAge(ledgerId: 42, branch: "agent/cursor-42", repo: "/r/app", ageDays: 1)]
        let found = Diagnostics.devHygiene(repos: repos, pending: pending, limits: .init())
        XCTAssertEqual(found.map(\.signature),
                       ["stale-pr:app#7", "merged-branches:app", "dirty-clone:app", "pending-review:41"])
        XCTAssertTrue(found.allSatisfy { $0.kind == .proposable && $0.severity == "notice" })
    }

    func testHelpers() {
        XCTAssertEqual(DiagnosticsLive.dispatchTitle("cursor: Fix the build (attempt 2)"), "Fix the build")
        XCTAssertEqual(DiagnosticsLive.dispatchTitle("claude: a: b"), "a: b")
        XCTAssertEqual(DiagnosticsLive.filterMerged(["main", "feature/x", "agent/cursor-1", "cur", ""],
                                                    base: "main", current: "cur"), ["feature/x"])
        XCTAssertTrue(DiagnosticsLive.isGreen(["SUCCESS", "skipped"]))
        XCTAssertFalse(DiagnosticsLive.isGreen(["SUCCESS", "FAILURE"]))
        XCTAssertFalse(DiagnosticsLive.isGreen(["IN_PROGRESS"]))
        XCTAssertFalse(DiagnosticsLive.isGreen([]))
    }

    func testCollectRespectsEnableAndThresholds() {
        var snap = Diagnostics.Snapshot(now: now)
        snap.waiting = [.init(taskId: "A", title: "t", reason: "gated: x", passes: 4, since: "t")]
        XCTAssertTrue(Diagnostics.collect(snapshot: snap, settings: nil)
            .filter { $0.signature.hasPrefix("queue-stuck") }.isEmpty)
        var settings = AgentsConfig.DetectorSettings()
        var thresholds = AgentsConfig.DetectorThresholds()
        thresholds.queueStuckPasses = 4
        settings.thresholds = thresholds
        XCTAssertEqual(Diagnostics.collect(snapshot: snap, settings: settings)
            .filter { $0.signature.hasPrefix("queue-stuck") }.count, 1)
        settings.disabled = [Diagnostics.ID.queueHealth]
        XCTAssertTrue(Diagnostics.collect(snapshot: snap, settings: settings)
            .filter { $0.signature.hasPrefix("queue-stuck") }.isEmpty)
    }
}
