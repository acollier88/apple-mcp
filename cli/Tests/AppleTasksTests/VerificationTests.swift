import XCTest
@testable import apple_tasks

final class VerificationTests: XCTestCase {
    func testDeletedIsCompleted() {
        XCTAssertEqual(Dispatch.verification(isCompleted: nil, tags: []), "completed")
    }

    func testCompletedReminder() {
        XCTAssertEqual(Dispatch.verification(isCompleted: true, tags: [ClaimTags.dispatched]), "completed")
    }

    func testOpenWithOwnClaim() {
        XCTAssertEqual(Dispatch.verification(isCompleted: false, tags: [ClaimTags.dispatched]), "open-claimed")
        XCTAssertEqual(Dispatch.verification(isCompleted: false, tags: ["dispatched"]), "open-claimed")
    }

    func testOpenUntagged() {
        XCTAssertEqual(Dispatch.verification(isCompleted: false, tags: ["auto"]), "open-untagged")
        XCTAssertEqual(Dispatch.verification(isCompleted: false, tags: []), "open-untagged")
    }

    func testForeignClaimIsOpenUntagged() {
        XCTAssertEqual(
            Dispatch.verification(isCompleted: false, tags: ["dispatched:otherhost"]),
            "open-untagged")
    }
}
