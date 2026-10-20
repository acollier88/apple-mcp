import XCTest
@testable import apple_tasks

final class RecurrenceTests: XCTestCase {
    func testDailyIntervalRoundTrip() throws {
        let input = "FREQ=DAILY;INTERVAL=2"
        XCTAssertEqual(Recurrence.format(try Recurrence.parse(input)), input)
    }

    func testWeeklyByDayRoundTrip() throws {
        let input = "FREQ=WEEKLY;BYDAY=MO,WE"
        XCTAssertEqual(Recurrence.format(try Recurrence.parse(input)), input)
    }

    func testMonthlyByMonthDayRoundTrip() throws {
        let input = "FREQ=MONTHLY;BYMONTHDAY=15"
        XCTAssertEqual(Recurrence.format(try Recurrence.parse(input)), input)
    }

    func testUntilRoundTrip() throws {
        let input = "FREQ=DAILY;UNTIL=2026-12-31"
        XCTAssertEqual(Recurrence.format(try Recurrence.parse(input)), input)
    }

    func testCountRoundTrip() throws {
        let input = "FREQ=WEEKLY;COUNT=10"
        XCTAssertEqual(Recurrence.format(try Recurrence.parse(input)), input)
    }

    func testUntilAndCountRejected() {
        XCTAssertThrowsError(try Recurrence.parse("FREQ=DAILY;UNTIL=2026-12-31;COUNT=5")) { error in
            guard case AppleTasksError.saveFailed(let why) = error else {
                return XCTFail("expected saveFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("UNTIL or COUNT"), why)
        }
    }

    func testHourlyRejected() {
        XCTAssertThrowsError(try Recurrence.parse("FREQ=HOURLY")) { error in
            guard case AppleTasksError.saveFailed(let why) = error else {
                return XCTFail("expected saveFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("FREQ=DAILY|WEEKLY|MONTHLY|YEARLY"), why)
        }
    }
}
