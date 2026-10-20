import XCTest
@testable import apple_tasks

final class TaskFingerprintTests: XCTestCase {
    func testStableForSameContent() {
        let a = TaskFingerprint.of(title: "[auto] Do x", notes: "n", dueText: "2026-09-08", url: nil, priority: 0)
        let b = TaskFingerprint.of(title: "[auto] Do x", notes: "n", dueText: "2026-09-08", url: nil, priority: 0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testDueRollChangesIt() {
        let a = TaskFingerprint.of(title: "t", notes: nil, dueText: "2026-09-08T05:45:00-05:00", url: nil, priority: 0)
        let b = TaskFingerprint.of(title: "t", notes: nil, dueText: "2026-09-09T05:45:00-05:00", url: nil, priority: 0)
        XCTAssertNotEqual(a, b)
    }

    func testTitleAndNotesEditsChangeIt() {
        let base = TaskFingerprint.of(title: "t", notes: "n", dueText: nil, url: nil, priority: 0)
        XCTAssertNotEqual(base, TaskFingerprint.of(title: "t2", notes: "n", dueText: nil, url: nil, priority: 0))
        XCTAssertNotEqual(base, TaskFingerprint.of(title: "t", notes: "n\n\n[dispatch #9] succeeded", dueText: nil, url: nil, priority: 0))
        XCTAssertNotEqual(base, TaskFingerprint.of(title: "t", notes: "n", dueText: nil, url: "https://x", priority: 0))
        XCTAssertNotEqual(base, TaskFingerprint.of(title: "t", notes: "n", dueText: nil, url: nil, priority: 5))
    }

    func testFieldBoundaryMatters() {
        // Moving text across the title/notes boundary must not collide.
        let a = TaskFingerprint.of(title: "ab", notes: "c", dueText: nil, url: nil, priority: 0)
        let b = TaskFingerprint.of(title: "a", notes: "bc", dueText: nil, url: nil, priority: 0)
        XCTAssertNotEqual(a, b)
    }

    func testNilAndEmptyAreEquivalent() {
        let a = TaskFingerprint.of(title: "t", notes: nil, dueText: nil, url: nil, priority: 0)
        let b = TaskFingerprint.of(title: "t", notes: "", dueText: nil, url: nil, priority: 0)
        XCTAssertEqual(a, b)
    }
}
