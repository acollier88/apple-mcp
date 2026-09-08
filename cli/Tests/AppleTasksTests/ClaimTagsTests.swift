import XCTest
@testable import apple_tasks

final class ClaimTagsTests: XCTestCase {
    func testDispatchedAndFailedAreHostScoped() {
        XCTAssertEqual(ClaimTags.dispatched, "dispatched:\(ClaimTags.host)")
        XCTAssertEqual(ClaimTags.failed, "failed:\(ClaimTags.host)")
        XCTAssertFalse(ClaimTags.host.contains("."))
        XCTAssertEqual(ClaimTags.host, ClaimTags.host.lowercased())
    }

    func testIsOwnAcceptsBareLegacyAndOwnHost() {
        XCTAssertTrue(ClaimTags.isOwn("dispatched"))
        XCTAssertTrue(ClaimTags.isOwn("failed"))
        XCTAssertTrue(ClaimTags.isOwn(ClaimTags.dispatched))
        XCTAssertTrue(ClaimTags.isOwn(ClaimTags.failed))
        XCTAssertTrue(ClaimTags.isOwn("DISPATCHED"))
        XCTAssertTrue(ClaimTags.isOwn("FAILED:\(ClaimTags.host.uppercased())"))
    }

    func testIsOwnRejectsOtherHost() {
        XCTAssertFalse(ClaimTags.isOwn("dispatched:other-mac"))
        XCTAssertFalse(ClaimTags.isOwn("failed:other-mac"))
    }

    func testIsDispatchedAndIsFailedRecognizeBareAndScoped() {
        XCTAssertTrue(ClaimTags.isDispatched("dispatched"))
        XCTAssertTrue(ClaimTags.isDispatched("dispatched:mbp"))
        XCTAssertFalse(ClaimTags.isDispatched("failed"))
        XCTAssertTrue(ClaimTags.isFailed("failed"))
        XCTAssertTrue(ClaimTags.isFailed("failed:mbp"))
        XCTAssertFalse(ClaimTags.isFailed("dispatched"))
    }

    func testSanitizeHostLowercasesFirstDNSLabel() {
        XCTAssertEqual(ClaimTags.sanitizeHost("MBP.local"), "mbp")
        XCTAssertEqual(ClaimTags.sanitizeHost("Andrews-MacBook-Pro.lan"), "andrews-macbook-pro")
        XCTAssertEqual(ClaimTags.sanitizeHost("Foo.Bar.Baz"), "foo")
        XCTAssertEqual(ClaimTags.sanitizeHost("My-Host"), "my-host")
        XCTAssertEqual(ClaimTags.sanitizeHost("!!!"), "mac")
        XCTAssertEqual(ClaimTags.sanitizeHost(""), "mac")
    }
}
