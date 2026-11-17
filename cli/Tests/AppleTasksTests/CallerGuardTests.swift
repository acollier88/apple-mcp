import XCTest
@testable import apple_tasks

final class CallerGuardTests: XCTestCase {
    func testSecretRefusesDispatchedAgents() {
        XCTAssertEqual(
            CallerGuard.secretRefusal(command: "secret get", caller: "agent:cursor"),
            "secret get is for the human user, not automated callers (APPLE_TASKS_CALLER=agent:cursor); "
                + "run it from your own terminal")
        XCTAssertNotNil(CallerGuard.secretRefusal(command: "secret set", caller: "agent:"))
        XCTAssertNotNil(CallerGuard.secretRefusal(command: "secret rm", caller: " Agent:claude "))
    }

    func testSecretRefusesMcp() {
        XCTAssertNotNil(CallerGuard.secretRefusal(command: "secret get", caller: "mcp"))
        XCTAssertNotNil(CallerGuard.secretRefusal(command: "secret migrate --apply", caller: "MCP"))
    }

    func testSecretAllowsHumansAndOtherCallers() {
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: nil))
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: ""))
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: "dispatcher"))
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: "mail-rule"))
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: "mcp-inspector"))
        XCTAssertNil(CallerGuard.secretRefusal(command: "secret get", caller: "zsh (pid 42)"))
    }

    func testApproveAnswerRefusesAgentsOnly() {
        XCTAssertEqual(
            CallerGuard.approvalAnswerRefusal(caller: "agent:claude"),
            "approve answer is not available to dispatched agents (APPLE_TASKS_CALLER=agent:claude); "
                + "the human answers via the ntfy buttons or their own terminal")
        // #28 scope is agent:* only; MCP has no answer tool by design.
        XCTAssertNil(CallerGuard.approvalAnswerRefusal(caller: "mcp"))
        XCTAssertNil(CallerGuard.approvalAnswerRefusal(caller: nil))
        XCTAssertNil(CallerGuard.approvalAnswerRefusal(caller: "dispatcher"))
    }

    func testEnforceNilIsNoop() throws {
        XCTAssertNoThrow(try CallerGuard.enforce(nil, command: "secret get", detail: "x"))
    }
}
