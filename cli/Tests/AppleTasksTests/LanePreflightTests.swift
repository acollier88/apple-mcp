import XCTest
@testable import apple_tasks

final class LanePreflightTests: XCTestCase {
    func testBootSettleAndNetworkHoldTheClaim() {
        let boot = LanePreflight.block(uptime: 30, networkUp: true, auth: .ready, isHealTarget: false)
        XCTAssertEqual(boot, .bootSettle(uptime: 30))
        XCTAssertTrue(LanePreflight.skipReason(boot!).hasPrefix("gated:"))

        let down = LanePreflight.block(uptime: 500, networkUp: false, auth: .ready, isHealTarget: false)
        XCTAssertEqual(down, .networkDown)
    }

    func testReadyLaneIsNotBlocked() {
        XCTAssertNil(LanePreflight.block(uptime: 500, networkUp: true, auth: .ready, isHealTarget: false))
        XCTAssertNil(LanePreflight.block(uptime: 500, networkUp: true, auth: nil, isHealTarget: false))
    }

    func testMissingLoginAndDeadBackendStayQueued() {
        let login = LanePreflight.block(
            uptime: 500, networkUp: true,
            auth: .needsHuman(command: "agent login"), isHealTarget: false)
        XCTAssertEqual(login, .authMissing(command: "agent login"))
        XCTAssertEqual(
            LanePreflight.skipReason(login!),
            "gated: login missing (agent login)")

        let dead = LanePreflight.block(
            uptime: 500, networkUp: true,
            auth: .unreachable("ollama down"), isHealTarget: false)
        XCTAssertEqual(dead, .backendUnreachable("ollama down"))
    }

    func testHealIsNotRoutedOntoTheLaneItHeals() {
        let agents: Set<String> = ["hermes", "heal", "cursor", "doctor"]
        XCTAssertEqual(
            LanePreflight.healTargetLane(tags: ["hermes", "heal", "auto"], agentNames: agents),
            "hermes")
        XCTAssertNil(LanePreflight.healTargetLane(tags: ["cursor", "auto"], agentNames: agents))
        XCTAssertEqual(
            LanePreflight.retargetHealLane(named: "hermes", healTarget: "hermes", hasHealLane: true),
            "heal")
        XCTAssertNil(LanePreflight.retargetHealLane(named: "cursor", healTarget: "hermes", hasHealLane: true))
        XCTAssertNil(LanePreflight.retargetHealLane(named: "hermes", healTarget: "hermes", hasHealLane: false))

        let blocked = LanePreflight.block(uptime: 500, networkUp: true, auth: .ready, isHealTarget: true)
        XCTAssertEqual(blocked, .healTarget)
    }

    func testAgentStatusDoesNotTreatAnAPIKeyAsLoggedOut() {
        XCTAssertEqual(
            LanePreflight.interpretAgentStatus(hasAPIKey: true, timedOut: true, exitCode: 1, output: ""),
            .ready)
        XCTAssertEqual(
            LanePreflight.interpretAgentStatus(
                hasAPIKey: false, timedOut: false, exitCode: 0,
                output: #"{"isAuthenticated": false, "userInfo": {"email": "hidden@example.com"}}"#),
            .needsHuman(command: "agent login"))
        XCTAssertEqual(
            LanePreflight.interpretAgentStatus(
                hasAPIKey: false, timedOut: false, exitCode: 0,
                output: #"{"isAuthenticated": true}"#),
            .ready)
    }

    func testMissingBinaryIsUnreachableNotALogin() {
        XCTAssertEqual(
            LanePreflight.interpretAgentStatus(hasAPIKey: false, timedOut: false, exitCode: 127,
                                               output: "env: agent: No such file or directory"),
            .unreachable("agent not found on PATH"))
        XCTAssertEqual(
            LanePreflight.interpretClaudeAuth(hasAPIKey: false, timedOut: false, exitCode: 127,
                                              output: "env: claude: No such file or directory"),
            .unreachable("claude not found on PATH"))
    }

    func testClaudeAuthAcceptsAPIKeyLine() {
        XCTAssertEqual(
            LanePreflight.interpretClaudeAuth(
                hasAPIKey: false, timedOut: false, exitCode: 0,
                output: "Auth token: claude.ai · not in use\nAPI key: ANTHROPIC_API_KEY\n"),
            .ready)
        XCTAssertEqual(
            LanePreflight.interpretClaudeAuth(
                hasAPIKey: false, timedOut: false, exitCode: 1, output: "Not logged in"),
            .needsHuman(command: "claude auth login"))
    }

    func testCronCredentialIsNeedsHumanPerJob() {
        let issues = LanePreflight.cronBlocked([
            .init(name: "morning brief", status: "blocked_config", error: "provider credential missing"),
            .init(name: "ok-job", status: "ok", error: nil),
        ])
        XCTAssertEqual(issues.map(\.signature), ["hermes-cron-blocked:morning-brief"])
        XCTAssertEqual(issues.first?.needsHumanCommand, "hermes config")
    }

    func testNeedsHumanNotifiesOncePerSignature() {
        let issues = [
            LanePreflight.Classified(signature: "lane-auth-missing:cursor", summary: "cursor", needsHumanCommand: "agent login"),
            LanePreflight.Classified(signature: "mcp-unavailable", summary: "mcp", needsHumanCommand: nil),
        ]
        let first = LanePreflight.signaturesToNotify(previous: nil, issues: issues)
        XCTAssertEqual(first.map(\.signature), ["lane-auth-missing:cursor"])
        let record = LanePreflight.signatureRecord(issues)
        XCTAssertEqual(LanePreflight.signaturesToNotify(previous: record, issues: issues).map(\.signature), [])
        let again = LanePreflight.signaturesToNotify(previous: "", issues: issues)
        XCTAssertEqual(again.map(\.signature), ["lane-auth-missing:cursor"])
    }

    func testMCPPhraseIsDetectedWithoutCopyingTheLog() {
        XCTAssertTrue(LanePreflight.mentionsMCPUnavailable(
            summary: nil, logTail: "MCP unavailable, falling back to the CLI"))
        XCTAssertFalse(LanePreflight.mentionsMCPUnavailable(summary: "ok", logTail: "done"))
        XCTAssertEqual(LanePreflight.mcpUnavailableIssue(mentioned: true)?.signature, "doctor-lane-mcp-fallback")
        XCTAssertNil(LanePreflight.mcpUnavailableIssue(mentioned: true)?.needsHumanCommand)
        XCTAssertNil(LanePreflight.mcpUnavailableIssue(mentioned: false))
    }
}
