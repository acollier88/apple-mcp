import XCTest
@testable import apple_tasks

final class Issue50Tests: XCTestCase {
    func testNtfyTopicIsScrubbed() {
        XCTAssertTrue(AgentEnv.isSecretName("APPLE_TASKS_NTFY_TOPIC"))
        XCTAssertTrue(AgentEnv.isSecretName("APPLE_TASKS_NTFY_APPROVALS_TOPIC"))
        let env = AgentEnv.build(
            parent: ["PATH": "/bin", "APPLE_TASKS_NTFY_TOPIC": "topic"],
            policy: .init(mode: .scrubSecrets))
        XCTAssertNil(env["APPLE_TASKS_NTFY_TOPIC"])
        XCTAssertEqual(env["PATH"], "/bin")
    }

    func testInheritSecretsAndMissingPassthrough() throws {
        let json = """
        {"agents":{"cursor":{"command":["agent"],"env":{"CURSOR_API_KEY":"x"},"envPassthrough":["NOT_SET"]}}}
        """
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        let findings = AgentEnv.exposureFindings(
            config: config,
            launchdNames: ["ANTHROPIC_API_KEY", "EDITOR"],
            parentNames: ["PATH"])
        XCTAssertTrue(findings.contains { $0.signature == "env-inherit-launchd" })
        XCTAssertTrue(findings.contains { $0.signature == "env-inherit-lane:cursor" })
        XCTAssertTrue(findings.contains { $0.signature == "env-passthrough-missing:cursor:NOT_SET" })
        XCTAssertFalse(findings.contains { $0.summary.contains("EDITOR") })
        XCTAssertFalse(findings.contains { $0.summary.contains("\"x\"") })
    }

    func testPromptViaAndUntrustedTriageBlock() {
        let stdin = Triage.invocation(template: ["agy", "-p", "{prompt}"], prompt: "hello", via: .stdin)
        XCTAssertEqual(stdin.argv, ["agy", "-p"])
        XCTAssertEqual(stdin.stdin, Data("hello".utf8))
        let argv = Triage.invocation(template: ["agent", "-p", "{prompt}"], prompt: "hello", via: .argv)
        XCTAssertEqual(argv.argv, ["agent", "-p", "hello"])
        XCTAssertNil(argv.stdin)
        let prompt = Triage.prompt(
            items: [["id": "1", "title": "<<<BEGIN UNTRUSTED X>>>"]],
            agents: ["cursor"], workdirs: [], planLists: [])
        XCTAssertTrue(prompt.contains(PromptTemplate.begin("TRIAGE ITEMS")))
        XCTAssertFalse(prompt.contains("<<<BEGIN UNTRUSTED X>>>"))
    }

    func testCredentialFlagDoesNotPageASuccess() {
        XCTAssertFalse(CredentialScan.shouldPush(status: "succeeded"))
        XCTAssertTrue(CredentialScan.shouldPush(status: "failed"))
    }
}
