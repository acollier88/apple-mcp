import ArgumentParser
import XCTest
@testable import apple_tasks

/// Pins the swift-argument-parser behaviour (Package.resolved 1.8.2) that the
/// MCP server (`opt()` / `positionals()` in mcp/src/lib.ts) and the HTTP
/// bridge (`RouteArgs.option`) rely on for #32. Parse only — never `run()`.
final class ArgvParsingTests: XCTestCase {
    private func root<T>(_ argv: [String], as _: T.Type,
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let command = try AppleTasks.parseAsRoot(argv)
        guard let typed = command as? T else {
            XCTFail("parsed \(type(of: command)), expected \(T.self)", file: file, line: line)
            throw ExitCode.failure
        }
        return typed
    }

    private func assertRejected(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AppleTasks.parseAsRoot(argv), "\(argv)", file: file, line: line)
    }

    // MARK: - The bug: unguarded free text

    func testDashTitleWithoutTerminatorIsNotATitle() {
        assertRejected(["add", "--list", "Inbox", "-x"])
        assertRejected(["add", "--list", "Inbox", "--help-me"])
    }

    func testSplitOptionValueStartingWithDashIsRejected() {
        // `--notes -x` is "Missing value for '--notes'", not notes "-x".
        assertRejected(["add", "--list", "Inbox", "--notes", "-x", "t"])
        assertRejected(["add", "--list", "Inbox", "--notes", "--list", "t"])
        assertRejected(["dispatch", "--dry-run", "--agent", "--reap-only"])
        assertRejected(["log", "--caller", "--limit", "5"])
    }

    // MARK: - The fix

    func testDoubleDashTerminatesOptionsForTitle() throws {
        let add = try root(["add", "--list=Inbox", "--", "-x"], as: Add.self)
        XCTAssertEqual(add.title, "-x")
        let flagLike = try root(["add", "--list=Inbox", "--", "--no-native-tags"], as: Add.self)
        XCTAssertEqual(flagLike.title, "--no-native-tags")
        XCTAssertFalse(flagLike.noNativeTags)
    }

    func testAttachedOptionValuesMayStartWithDash() throws {
        let add = try root(["add", "--list=-Inbox", "--tag=-t", "--notes=--list", "--", "t"], as: Add.self)
        XCTAssertEqual(add.listName, "-Inbox")
        XCTAssertEqual(add.tags, ["-t"])
        XCTAssertEqual(add.notes, "--list")
        XCTAssertEqual(add.title, "t")

        let withEquals = try root(["add", "--list=Inbox", "--notes=a=b", "--", "t"], as: Add.self)
        XCTAssertEqual(withEquals.notes, "a=b")
    }

    func testEmptyValueNeedsSplitForm() throws {
        // Why opt() keeps `[flag, ""]` for empty strings.
        assertRejected(["add", "--list=Inbox", "--notes=", "--", "t"])
        let add = try root(["add", "--list=Inbox", "--notes", "", "--", "t"], as: Add.self)
        XCTAssertEqual(add.notes, "")
    }

    func testUpdateIdBehindTerminator() throws {
        let update = try root(["update", "--title=--help", "--notes", "", "--", "-T1"], as: Update.self)
        XCTAssertEqual(update.id, "-T1")
        XCTAssertEqual(update.title, "--help")
        XCTAssertEqual(update.notes, "")
    }

    func testNotifyBothPositionalsBehindTerminator() throws {
        let notify = try root(["notify", "--sound", "--", "-t", "--push"], as: NotifyCommand.self)
        XCTAssertEqual(notify.title, "-t")
        XCTAssertEqual(notify.message, "--push")
        XCTAssertFalse(notify.push)
        XCTAssertTrue(notify.sound)
    }

    func testOptionsAfterTerminatorAreNotOptions() {
        // positionals() must be last: nothing after `--` is an option.
        assertRejected(["add", "--list=Inbox", "--", "t", "--notes=x"])
    }

    func testIntOptionsAndNegativePositionals() throws {
        let log = try root(["log", "--limit=5", "--caller=--limit", "--since=-1"], as: Log.self)
        XCTAssertEqual(log.limit, 5)
        XCTAssertEqual(log.caller, "--limit")
        XCTAssertEqual(log.since, "-1")

        let dispatch = try root(["dispatch", "--dry-run", "--agent=--reap-only", "--reap-hours=3"],
                                as: Dispatch.self)
        XCTAssertEqual(dispatch.onlyAgent, "--reap-only")
        XCTAssertFalse(dispatch.reapOnly)
        XCTAssertEqual(dispatch.reapHours, 3)
    }

    func testNestedSubcommandsAcceptTerminator() throws {
        let fetch = try root(["web", "fetch", "--max-chars=10", "--", "-x"], as: WebGet.self)
        XCTAssertEqual(fetch.url, "-x")
        XCTAssertEqual(fetch.maxChars, 10)
        let event = try root(["events", "add", "--start=2026-01-01", "--location=-room", "--", "-standup"],
                             as: EventsAdd.self)
        XCTAssertEqual(event.title, "-standup")
        XCTAssertEqual(event.location, "-room")
    }
}
