import XCTest
@testable import apple_tasks

final class TriageParseTests: XCTestCase {
    private struct Item: Decodable, Equatable {
        let n: Int
    }

    func testToleratesJSONFenceAndProse() throws {
        let raw = """
        Here is the classification:
        ```json
        [{"n": 1}, {"n": 2}]
        ```
        done.
        """
        XCTAssertEqual(try Triage.parseJSONArray(raw) as [Item], [Item(n: 1), Item(n: 2)])
    }

    func testToleratesLeadingProseAndTrailingText() throws {
        let raw = "Sure — use this: [{\"n\":3}] thanks"
        XCTAssertEqual(try Triage.parseJSONArray(raw) as [Item], [Item(n: 3)])
    }

    func testRejectsNonArray() {
        XCTAssertThrowsError(try Triage.parseJSONArray("{\"n\":1}") as [Item]) { error in
            guard case AppleTasksError.saveFailed(let why) = error else {
                return XCTFail("expected saveFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("no JSON array"), why)
        }
    }
}
