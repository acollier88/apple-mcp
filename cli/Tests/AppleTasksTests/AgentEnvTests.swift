import XCTest
@testable import apple_tasks

final class AgentEnvTests: XCTestCase {
    let parent: [String: String] = [
        "PATH": "/usr/bin",
        "HOME": "/Users/me",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
        "CURSOR_API_KEY": "c-secret",
        "ANTHROPIC_API_KEY": "a-secret",
        "GH_TOKEN": "g-secret",
        "PGPASSWORD": "p",
        "AWS_SECRET_ACCESS_KEY": "s",
        "GOOGLE_APPLICATION_CREDENTIALS": "/x.json",
        "EDITOR": "vim",
        "APPLE_TASKS_CALLER": "mcp",
    ]

    func testInheritKeepsEverything() {
        let env = AgentEnv.build(parent: parent, policy: .init())
        XCTAssertEqual(env, parent)
    }

    func testScrubDropsSecretLookingNamesOnly() {
        let env = AgentEnv.build(parent: parent, policy: .init(mode: .scrubSecrets))
        for name in ["CURSOR_API_KEY", "ANTHROPIC_API_KEY", "GH_TOKEN", "PGPASSWORD",
                     "AWS_SECRET_ACCESS_KEY", "GOOGLE_APPLICATION_CREDENTIALS"] {
            XCTAssertNil(env[name], name)
        }
        for name in ["PATH", "HOME", "LANG", "LC_ALL", "SSH_AUTH_SOCK", "EDITOR"] {
            XCTAssertEqual(env[name], parent[name], name)
        }
    }

    func testScrubKeepsPassthrough() {
        let env = AgentEnv.build(parent: parent,
                                 policy: .init(mode: .scrubSecrets, passthrough: ["CURSOR_API_KEY"]))
        XCTAssertEqual(env["CURSOR_API_KEY"], "c-secret")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    func testAllowlistKeepsBaseSetAndPassthrough() {
        let env = AgentEnv.build(parent: parent,
                                 policy: .init(mode: .allowlist, passthrough: ["ANTHROPIC_API_KEY", "NOT_SET"]))
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "LANG", "LC_ALL", "ANTHROPIC_API_KEY"])
    }

    func testOverlayCallerAndPathApplyOnTopInEveryMode() {
        for mode in [AgentEnv.Mode.inherit, .scrubSecrets, .allowlist] {
            let env = AgentEnv.build(
                parent: parent,
                policy: .init(mode: mode, overlay: ["OPENAI_API_KEY": "explicit", "PATH": "/lane"]),
                caller: "agent:cursor",
                searchPath: { "/prefix:" + ($0 ?? "") })
            XCTAssertEqual(env["OPENAI_API_KEY"], "explicit", "\(mode)")
            XCTAssertEqual(env["APPLE_TASKS_CALLER"], "agent:cursor", "\(mode)")
            XCTAssertEqual(env["PATH"], "/prefix:/lane", "\(mode)")
        }
    }

    func testDroppedNamesListsNamesNotValues() {
        let dropped = AgentEnv.droppedNames(parent: parent,
                                            policy: .init(mode: .scrubSecrets, passthrough: ["GH_TOKEN"]))
        XCTAssertEqual(dropped, ["ANTHROPIC_API_KEY", "AWS_SECRET_ACCESS_KEY", "CURSOR_API_KEY",
                                 "GOOGLE_APPLICATION_CREDENTIALS", "PGPASSWORD"])
    }

    func testResolveLaneOverridesTopLevelAndAddsLlmKeyEnv() throws {
        let json = #"""
        {"envMode": "allowlist",
         "agents": {
           "a": {"command": ["x"]},
           "b": {"command": ["y"], "envMode": "inherit"},
           "c": {"llm": {"endpoint": "http://h/v1", "model": "m", "apiKeyEnv": "MY_LLM_KEY"},
                 "envMode": "scrubSecrets", "envPassthrough": ["GH_TOKEN"], "env": {"K": "v"}}
         }}
        """#
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(AgentEnv.Policy.resolve(lane: config.agents["a"], config: config).mode, .allowlist)
        XCTAssertEqual(AgentEnv.Policy.resolve(lane: config.agents["b"], config: config).mode, .inherit)
        let c = AgentEnv.Policy.resolve(lane: config.agents["c"], config: config)
        XCTAssertEqual(c.mode, .scrubSecrets)
        XCTAssertEqual(c.passthrough, ["GH_TOKEN", "MY_LLM_KEY"])
        XCTAssertEqual(c.overlay, ["K": "v"])
    }

    func testDefaultIsInheritWhenUnset() throws {
        let json = #"{"agents": {"a": {"command": ["x"]}}}"#
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(AgentEnv.Policy.resolve(lane: config.agents["a"], config: config), AgentEnv.Policy())
        XCTAssertEqual(AgentEnv.Policy.resolve(lane: nil, config: nil).mode, .inherit)
    }

    func testExampleConfigDecodesWithRecommendedEnv() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/agents.json")
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(config.envMode, .scrubSecrets)
        XCTAssertEqual(config.agents["cursor"]?.envPassthrough, ["CURSOR_API_KEY"])
        XCTAssertEqual(config.agents["claude"]?.envPassthrough, ["ANTHROPIC_API_KEY"])
        for (tag, lane) in config.agents {
            if let template = lane.promptTemplate {
                XCTAssertTrue(template.contains(PromptTemplate.begin("TASK NOTES")), tag)
            }
        }
    }

    func testUnknownEnvModeRejected() {
        let json = #"{"agents": {"a": {"command": ["x"], "envMode": "sandbox"}}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8)))
    }
}
