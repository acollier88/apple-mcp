import XCTest
@testable import apple_tasks

final class WatchdogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let eightHours = Watchdog.maxPassSeconds(config: nil)

    private func beat(_ role: String, startedAgo: TimeInterval, finishedAgo: TimeInterval?) -> Watchdog.Beat {
        Watchdog.Beat(role: role, pid: 10,
                      started: Watchdog.stamp(now.addingTimeInterval(-startedAgo)),
                      finished: finishedAgo.map { Watchdog.stamp(now.addingTimeInterval(-$0)) })
    }

    func testALongButLegalPassIsNotAnAlert() {
        // A 40-minute pass is normal: agents run for up to their lane timeout,
        // and the dispatcher's own cap is 8 hours (#75).
        let running = beat("dispatcher", startedAgo: 40 * 60, finishedAgo: nil)
        XCTAssertTrue(Watchdog.notices(dispatcher: running, watchdog: nil, now: now,
                                       deadRunning: 0, maxPass: eightHours).isEmpty)
        let stuck = beat("dispatcher", startedAgo: eightHours + 60, finishedAgo: nil)
        XCTAssertEqual(Watchdog.notices(dispatcher: stuck, watchdog: nil, now: now,
                                        deadRunning: 0, maxPass: eightHours),
                       [.passTooLong(Int(eightHours + 60))])
    }

    func testSilenceDeadRowsAndASilentWatchdog() {
        let finished = beat("dispatcher", startedAgo: 60 * 60, finishedAgo: 30 * 60)
        let dog = beat("watchdog", startedAgo: 30 * 60, finishedAgo: 30 * 60)
        XCTAssertEqual(
            Watchdog.notices(dispatcher: finished, watchdog: dog, now: now, deadRunning: 2, maxPass: eightHours),
            [.noRecentPass(1800), .deadRunning(2), .watchdogSilent(1800)])
        // A watchdog that was never installed is not "silent".
        XCTAssertEqual(
            Watchdog.notices(dispatcher: nil, watchdog: dog, now: now, deadRunning: 0,
                             maxPass: eightHours, watchdogInstalled: false),
            [])
        let fresh = beat("dispatcher", startedAgo: 60, finishedAgo: 30)
        XCTAssertTrue(Watchdog.notices(dispatcher: fresh, watchdog: nil, now: now,
                                       deadRunning: 0, maxPass: eightHours).isEmpty)
    }

    func testQueuedRowsAreNotDead() {
        XCTAssertEqual(Watchdog.deadRunningCount(rows: [
            (pid: nil, alive: false),   // claimed, agent not started yet
            (pid: 4, alive: true),
            (pid: 5, alive: false),
        ]), 1)
    }

    func testAlertsPageOncePerCondition() {
        let current: [Watchdog.Notice] = [.noRecentPass(1800), .deadRunning(1)]
        XCTAssertEqual(Watchdog.newAlerts(current: current, previous: []), current)
        // Same conditions, minutes changed: no new page.
        XCTAssertEqual(Watchdog.newAlerts(current: [.noRecentPass(2400), .deadRunning(1)],
                                          previous: Set(current.map(Watchdog.signature))), [])
        XCTAssertEqual(Watchdog.newAlerts(current: [.passTooLong(1)],
                                          previous: Set(current.map(Watchdog.signature))),
                       [.passTooLong(1)])
    }

    func testHeartbeatRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let beat = Watchdog.Beat(role: "dispatcher", pid: 7, started: "2026-11-17T00:00:00Z", finished: nil)
        try Watchdog.write(beat, to: dir)
        XCTAssertEqual(Watchdog.read(role: "dispatcher", from: dir), beat)
        XCTAssertNil(Watchdog.read(role: "watchdog", from: dir))
        Watchdog.writeAlerted(["watchdog-silent"], dir)
        XCTAssertEqual(Watchdog.readAlerted(dir), ["watchdog-silent"])
    }
}
