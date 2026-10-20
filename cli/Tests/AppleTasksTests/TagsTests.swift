import XCTest
@testable import apple_tasks

final class TagsTests: XCTestCase {
    func testParseComposeRoundTripLeadingTags() {
        let raw = "[a][b] Title"
        let parsed = Tags.parse(raw)
        XCTAssertEqual(parsed.tags, ["a", "b"])
        XCTAssertEqual(parsed.title, "Title")
        XCTAssertEqual(Tags.compose(tags: parsed.tags, title: parsed.title), raw)
    }

    func testParseAllowsWhitespaceBetweenGroups() {
        let parsed = Tags.parse("[a] [b] Title")
        XCTAssertEqual(parsed.tags, ["a", "b"])
        XCTAssertEqual(parsed.title, "Title")
        // NOTE: compose emits no space between groups.
        XCTAssertEqual(Tags.compose(tags: parsed.tags, title: parsed.title), "[a][b] Title")
    }

    func testTrailingBracketsStayInTitle() {
        let parsed = Tags.parse("Title [x]")
        XCTAssertEqual(parsed.tags, [])
        XCTAssertEqual(parsed.title, "Title [x]")
        XCTAssertEqual(Tags.compose(tags: parsed.tags, title: parsed.title), "Title [x]")
    }

    func testEmptyBracketsAreNotATag() {
        let parsed = Tags.parse("[]")
        XCTAssertEqual(parsed.tags, [])
        XCTAssertEqual(parsed.title, "[]")
    }

    func testSpacedBracketsStayInTitle() {
        let parsed = Tags.parse("[a b] leftover")
        XCTAssertEqual(parsed.tags, [])
        XCTAssertEqual(parsed.title, "[a b] leftover")
    }

    func testUnicodeTag() {
        let parsed = Tags.parse("[任务] 标题")
        XCTAssertEqual(parsed.tags, ["任务"])
        XCTAssertEqual(parsed.title, "标题")
        XCTAssertEqual(Tags.compose(tags: parsed.tags, title: parsed.title), "[任务] 标题")
    }

    func testValidateRejectsSpacesAndBrackets() {
        XCTAssertThrowsError(try Tags.validate("")) { error in
            guard case AppleTasksError.invalidTag("") = error else {
                return XCTFail("expected invalidTag, got \(error)")
            }
        }
        XCTAssertThrowsError(try Tags.validate("a b"))
        XCTAssertThrowsError(try Tags.validate("a[b"))
        XCTAssertThrowsError(try Tags.validate("a]b"))
    }

    func testValidateAcceptsKebabCase() {
        XCTAssertNoThrow(try Tags.validate("sign-in"))
        XCTAssertNoThrow(try Tags.validate("cursor"))
    }
}
