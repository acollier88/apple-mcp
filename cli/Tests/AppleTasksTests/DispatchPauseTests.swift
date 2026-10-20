import Foundation
import XCTest
@testable import apple_tasks

final class DispatchPauseTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-pause-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: Duration parser

    func testDurationParserValid() throws {
        XCTAssertEqual(try DispatchDuration.parse("30m"), 30 * 60)
        XCTAssertEqual(try DispatchDuration.parse("2h"), 2 * 3600)
        XCTAssertEqual(try DispatchDuration.parse("1d"), 86_400)
        XCTAssertEqual(try DispatchDuration.parse("90s"), 90)
        XCTAssertEqual(try DispatchDuration.parse(" 2H "), 2 * 3600)
        XCTAssertEqual(try DispatchDuration.parse("1.5h"), 1.5 * 3600)
    }

    func testDurationParserInvalid() {
        for raw in ["", "30", "30x", "-2h", "0m", "m", "2 hours", "s"] {
            XCTAssertThrowsError(try DispatchDuration.parse(raw), raw) { error in
                guard case AppleTasksError.invalidInput = error else {
                    return XCTFail("expected invalidInput for '\(raw)', got \(error)")
                }
            }
        }
    }

    // MARK: pauseGate (pure)

    func testPauseGateActive() {
        let until = Date().addingTimeInterval(3600)
        let iso = Dispatch.formatPausedUntil(until)
        let pause = Dispatch.pauseGate(now: Date(), state: [
            Dispatch.pausedUntilKey: iso,
            Dispatch.pauseReasonKey: "maintenance",
        ])
        XCTAssertEqual(pause?.untilISO, iso)
        XCTAssertEqual(pause?.reason, "maintenance")
        XCTAssertEqual(pause?.action, "paused until \(iso) (maintenance)")
    }

    func testPauseGateExpiredIsNil() {
        let iso = Dispatch.formatPausedUntil(Date().addingTimeInterval(-60))
        XCTAssertNil(Dispatch.pauseGate(now: Date(), state: [
            Dispatch.pausedUntilKey: iso,
            Dispatch.pauseReasonKey: "old",
        ]))
    }

    func testPauseGateEmptyOrMissingIsNil() {
        XCTAssertNil(Dispatch.pauseGate(now: Date(), state: [:]))
        XCTAssertNil(Dispatch.pauseGate(now: Date(), state: [
            Dispatch.pausedUntilKey: "",
            Dispatch.pauseReasonKey: "leftover",
        ]))
        XCTAssertNil(Dispatch.pauseGate(now: Date(), state: [
            Dispatch.pausedUntilKey: "not-a-date",
        ]))
    }

    func testShouldEmitPausedReportQuietCollapse() {
        let until = Date().addingTimeInterval(3600)
        let iso = Dispatch.formatPausedUntil(until)
        let pause = Dispatch.pauseGate(now: Date(), state: [Dispatch.pausedUntilKey: iso])!
        XCTAssertTrue(Dispatch.shouldEmitPausedReport(quiet: false, lastReported: pause.identity, pause: pause))
        XCTAssertTrue(Dispatch.shouldEmitPausedReport(quiet: true, lastReported: nil, pause: pause))
        XCTAssertTrue(Dispatch.shouldEmitPausedReport(quiet: true, lastReported: "", pause: pause))
        XCTAssertFalse(Dispatch.shouldEmitPausedReport(quiet: true, lastReported: pause.identity, pause: pause))
        XCTAssertTrue(Dispatch.shouldEmitPausedReport(quiet: true, lastReported: "other", pause: pause))
    }

    // MARK: temp-DB round-trip

    func testPauseStatusResumeRoundTrip() throws {
        let db = openDB()
        XCTAssertTrue(db.isAvailable)
        let until = Date().addingTimeInterval(3600)
        let paused = try Dispatch.applyPause(db: db, until: until, reason: "maintenance")
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.reason, "maintenance")
        XCTAssertEqual(db.getState(Dispatch.pausedUntilKey), paused.until)
        XCTAssertEqual(db.getState(Dispatch.pauseReasonKey), "maintenance")

        let status = Dispatch.applyStatus(db: db)
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.until, paused.until)
        XCTAssertEqual(status.reason, "maintenance")
        XCTAssertNotNil(status.remainingSeconds)
        XCTAssertGreaterThan(status.remainingSeconds ?? 0, 0)
        XCTAssertLessThanOrEqual(status.remainingSeconds ?? 0, 3600)

        let resumed = Dispatch.applyResume(db: db)
        XCTAssertFalse(resumed.paused)
        XCTAssertEqual(resumed.wasPausedUntil, paused.until)
        XCTAssertEqual(db.getState(Dispatch.pausedUntilKey), "")
        XCTAssertEqual(db.getState(Dispatch.pauseReasonKey), "")

        let after = Dispatch.applyStatus(db: db)
        XCTAssertFalse(after.paused)
        XCTAssertNil(after.until)
        XCTAssertNil(after.reason)
        XCTAssertNil(after.remainingSeconds)
    }

    func testExpiredPauseReadsAsNotPausedAndClears() throws {
        let db = openDB()
        let past = Dispatch.formatPausedUntil(Date().addingTimeInterval(-120))
        db.setState(Dispatch.pausedUntilKey, past)
        db.setState(Dispatch.pauseReasonKey, "stale")

        XCTAssertNil(Dispatch.pauseGate(now: Date(), state: Dispatch.pauseKV(db)))

        let status = Dispatch.applyStatus(db: db)
        XCTAssertFalse(status.paused)
        XCTAssertEqual(db.getState(Dispatch.pausedUntilKey), "")
        XCTAssertEqual(db.getState(Dispatch.pauseReasonKey), "")
    }

    func testApplyPauseRejectsPastUntil() {
        let db = openDB()
        XCTAssertThrowsError(try Dispatch.applyPause(
            db: db, until: Date().addingTimeInterval(-10), reason: nil)) { error in
            guard case AppleTasksError.invalidInput = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
        }
    }
}
