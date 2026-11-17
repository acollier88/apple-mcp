import XCTest
@testable import apple_tasks

final class WatchdogTests: XCTestCase {
    func testStalePassDeadRowsAndSilentWatchdog() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let running = Watchdog.Beat(role: "dispatcher", pid: 10,
                                    started: Watchdog.stamp(now.addingTimeInterval(-40 * 60)),
                                    finished: nil)
        XCTAssertEqual(
            Watchdog.notices(dispatcher: running, watchdog: nil, now: now, deadRunning: 0),
            [.passTooLong(2400)])

        let finished = Watchdog.Beat(role: "dispatcher", pid: 10,
                                     started: Watchdog.stamp(now.addingTimeInterval(-60 * 60)),
                                     finished: Watchdog.stamp(now.addingTimeInterval(-20 * 60)))
        let dog = Watchdog.Beat(role: "watchdog", pid: 11,
                                started: Watchdog.stamp(now.addingTimeInterval(-20 * 60)),
                                finished: Watchdog.stamp(now.addingTimeInterval(-20 * 60)))
        XCTAssertEqual(
            Watchdog.notices(dispatcher: finished, watchdog: dog, now: now, deadRunning: 2),
            [.noRecentPass(1200), .deadRunning(2), .watchdogSilent(1200)])

        let fresh = Watchdog.Beat(role: "dispatcher", pid: 10,
                                  started: Watchdog.stamp(now.addingTimeInterval(-60)),
                                  finished: Watchdog.stamp(now.addingTimeInterval(-30)))
        XCTAssertTrue(Watchdog.notices(dispatcher: fresh, watchdog: nil, now: now, deadRunning: 0).isEmpty)
        XCTAssertEqual(Watchdog.deadRunningCount(rows: [(pid: nil, alive: false), (pid: 4, alive: true), (pid: 5, alive: false)]), 2)
    }

    func testHeartbeatRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let beat = Watchdog.Beat(role: "dispatcher", pid: 7, started: "2026-11-17T00:00:00Z", finished: nil)
        try Watchdog.write(beat, to: dir)
        XCTAssertEqual(Watchdog.read(role: "dispatcher", from: dir), beat)
        XCTAssertNil(Watchdog.read(role: "watchdog", from: dir))
    }
}
