import XCTest
@testable import apple_tasks

final class RemirrorTagsTests: XCTestCase {
    func testPrunesClaimChipsMissingFromTitle() {
        let native = ["auto", "cursor", "dispatchedandrews-mac-mini", "dispatchedandrews-mac-mini", "failedmbp"]
        let stale = RemirrorTags.staleClaimChips(native: native, titleTags: ["auto", "cursor"])
        // One entry per stale name, duplicates collapsed; never touches non-claim tags.
        XCTAssertEqual(stale, ["dispatchedandrews-mac-mini", "failedmbp"])
    }

    func testKeepsClaimChipStillInTitle() {
        let native = ["auto", "dispatchedandrews-mac-mini"]
        let stale = RemirrorTags.staleClaimChips(
            native: native, titleTags: ["auto", "dispatched:andrews-mac-mini"])
        XCTAssertTrue(stale.isEmpty, "title still carries the claim; native chip must stay")
    }

    func testBareLegacyClaimChip() {
        XCTAssertEqual(RemirrorTags.staleClaimChips(native: ["Dispatched"], titleTags: []), ["Dispatched"])
        XCTAssertEqual(RemirrorTags.staleClaimChips(native: ["dispatched"], titleTags: ["dispatched"]), [])
    }

    func testIgnoresUnrelatedNativeTags() {
        let stale = RemirrorTags.staleClaimChips(native: ["hermes-agent", "personal"], titleTags: ["auto"])
        XCTAssertTrue(stale.isEmpty)
    }
}
