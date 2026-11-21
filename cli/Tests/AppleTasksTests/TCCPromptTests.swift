import EventKit
import XCTest
@testable import apple_tasks

final class TCCPromptTests: XCTestCase {
    func testOnlyUnanswerableCallersFailFast() {
        let launchd = ["XPC_SERVICE_NAME": "com.apple-tasks.dispatch"]
        XCTAssertTrue(Store.promptIsUnanswerable(status: .notDetermined, caller: "agent:cursor", env: [:]))
        XCTAssertTrue(Store.promptIsUnanswerable(status: .notDetermined, caller: nil, env: launchd))
        XCTAssertFalse(Store.promptIsUnanswerable(status: .notDetermined, caller: nil, env: [:]), "terminal")
        XCTAssertFalse(Store.promptIsUnanswerable(status: .notDetermined, caller: "mcp", env: [:]), "MCP host app")
        XCTAssertFalse(Store.promptIsUnanswerable(
            status: .notDetermined, caller: nil, env: ["XPC_SERVICE_NAME": "application.dev.collier.agenttasks"]))
        XCTAssertFalse(Store.promptIsUnanswerable(status: .fullAccess, caller: "agent:cursor", env: launchd))
        XCTAssertFalse(Store.promptIsUnanswerable(status: .denied, caller: "agent:cursor", env: [:]),
                       "denied answers at once; no prompt to wait for")
        XCTAssertFalse(Store.promptIsUnanswerable(
            status: .notDetermined, caller: "agent:cursor", env: ["APPLE_TASKS_WAIT_FOR_TCC": "1"]))
    }

    func testCalendarsAreAPermissionCheck() {
        let found = Diagnostics.permissions([.init(name: "reminders", status: "fullAccess"),
                                             .init(name: "calendars", status: "notDetermined")])
        XCTAssertEqual(found.map(\.signature), ["permission-missing:calendars"])
        XCTAssertTrue(AppleTasksError.accessNotGranted("Calendars").description.contains("events list"))
    }
}
