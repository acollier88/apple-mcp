import XCTest
@testable import apple_tasks

final class DispatchRetryTests: XCTestCase {
    func testShedsEveryFailedTagAndKeepsAuto() {
        let next = DispatchRetry.requeueTags(["cursor", "auto", "failed", ClaimTags.failed, "failed:other-mac"])
        XCTAssertEqual(next?.tags, ["cursor", "auto"])
        XCTAssertEqual(next?.removed, ["failed", ClaimTags.failed, "failed:other-mac"])
        XCTAssertEqual(next?.addedAuto, false)
    }

    func testRestoresAutoDroppedByManualFail() {
        let next = DispatchRetry.requeueTags(["claude", "apple-mcp", "failed"])
        XCTAssertEqual(next?.tags, ["auto", "claude", "apple-mcp"])
        XCTAssertEqual(next?.addedAuto, true)
    }

    func testAutoMatchIsCaseInsensitive() {
        XCTAssertEqual(DispatchRetry.requeueTags(["AUTO", "failed"])?.addedAuto, false)
    }

    func testRefusesWhileClaimed() {
        XCTAssertNil(DispatchRetry.requeueTags(["auto", ClaimTags.dispatched]))
        XCTAssertNil(DispatchRetry.requeueTags(["auto", "dispatched:other-mac", "failed"]))
    }
}
