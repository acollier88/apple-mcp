import XCTest
@testable import apple_tasks

final class TimeWindowTests: XCTestCase {
    private func date(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 7
        comps.hour = hour
        comps.minute = minute
        guard let date = Calendar.current.date(from: comps) else {
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    func testMidnightWrapContains0100Excludes1200() {
        let window = TimeWindow(notBetween: ["23:00", "06:00"])
        XCTAssertEqual(window.check(now: date(hour: 1, minute: 0)).isInside, true)
        XCTAssertEqual(window.check(now: date(hour: 12, minute: 0)).isInside, false)
        XCTAssertEqual(window.check(now: date(hour: 23, minute: 0)).isInside, true)
        XCTAssertEqual(window.check(now: date(hour: 6, minute: 0)).isInside, false)
    }

    func testSameDayBoundariesStartInclusiveEndExclusive() {
        let window = TimeWindow(notBetween: ["09:00", "17:00"])
        XCTAssertEqual(window.check(now: date(hour: 9, minute: 0)).isInside, true)
        XCTAssertEqual(window.check(now: date(hour: 16, minute: 59)).isInside, true)
        XCTAssertEqual(window.check(now: date(hour: 17, minute: 0)).isInside, false)
        XCTAssertEqual(window.check(now: date(hour: 8, minute: 59)).isInside, false)
    }

    func testEmptyWindowWhenStartEqualsEnd() {
        let window = TimeWindow(notBetween: ["12:00", "12:00"])
        XCTAssertEqual(window.check(now: date(hour: 12, minute: 0)).isInside, false)
        XCTAssertEqual(window.check(now: date(hour: 12, minute: 1)).isInside, false)
    }

    func testMalformedInputIsInvalid() {
        XCTAssertTrue(TimeWindow(notBetween: ["xx", "yy"]).check().isInvalid)
        XCTAssertTrue(TimeWindow(notBetween: ["25:00", "06:00"]).check().isInvalid)
        XCTAssertTrue(TimeWindow(notBetween: ["10:00"]).check().isInvalid)
        XCTAssertTrue(TimeWindow(notBetween: []).check().isInvalid)
    }
}

private extension TimeWindow.Check {
    var isInside: Bool {
        if case .inside = self { return true }
        return false
    }

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}
