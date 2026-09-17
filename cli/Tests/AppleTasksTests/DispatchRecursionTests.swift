import XCTest
@testable import apple_tasks

final class DispatchRecursionTests: XCTestCase {
    func testAgentLiveRefuses() {
        let message = Dispatch.recursionRefusal(caller: "agent:cursor", dryRun: false, reapOnly: false)
        XCTAssertEqual(
            message,
            "dispatch is not available to dispatched agents (APPLE_TASKS_CALLER=agent:cursor); use --dry-run to inspect")
    }

    func testAgentDryRunAllowed() {
        XCTAssertNil(Dispatch.recursionRefusal(caller: "agent:cursor", dryRun: true, reapOnly: false))
    }

    func testAgentReapOnlyAllowed() {
        XCTAssertNil(Dispatch.recursionRefusal(caller: "agent:cursor", dryRun: false, reapOnly: true))
    }

    func testMcpAllowed() {
        XCTAssertNil(Dispatch.recursionRefusal(caller: "mcp", dryRun: false, reapOnly: false))
    }

    func testNilCallerAllowed() {
        XCTAssertNil(Dispatch.recursionRefusal(caller: nil, dryRun: false, reapOnly: false))
    }
}
