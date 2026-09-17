import Foundation
import XCTest
@testable import apple_tasks

final class JevTests: XCTestCase {

    // MARK: - request encoding

    func testRequestEncodingIncludesStateQuestionsAndBearerHeader() async throws {
        let envName = "JEV_TEST_KEY_ENCODING"
        setenv(envName, "test-secret", 1)
        defer { unsetenv(envName) }

        let captured = Box<URLRequest?>(nil)
        let transport: JevClient.Transport = { request in
            captured.value = request
            return (Self.okJSON(answers: [
                "kind": Self.choice("agent", confidence: 0.9)
            ]), 200)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])

        _ = try await JevClassifier.classify(
            items: [["id": "1", "title": "fix the build", "notes": "cli target"]],
            agents: ["cursor", "claude"],
            workdirs: ["apple-mcp"],
            planLists: ["Work"],
            config: config,
            client: client)

        guard let request = captured.value else {
            return XCTFail("transport was not called")
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("request body was not a JSON object")
        }
        XCTAssertEqual(json["model"] as? String, "jev-latest")
        let state = json["state"] as? [String: Any]
        XCTAssertEqual(state?["title"] as? String, "fix the build")
        XCTAssertEqual(state?["notes"] as? String, "cli target")

        let questions = json["questions"] as? [String: Any]
        let kind = questions?["kind"] as? [String: Any]
        XCTAssertEqual(kind?["type"] as? String, "choice")
        let kindCriteria = kind?["criteria"] as? [String: Any]
        XCTAssertNotNil(kindCriteria?["agent"])
        XCTAssertNotNil(kindCriteria?["personal"])
        XCTAssertEqual(kindCriteria?.count, 2)

        let lane = questions?["lane"] as? [String: Any]
        XCTAssertEqual(lane?["type"] as? String, "choice")
        let laneCriteria = lane?["criteria"] as? [String: Any]
        XCTAssertNotNil(laneCriteria?["none"])
        XCTAssertNotNil(laneCriteria?["cursor"])
        XCTAssertNotNil(laneCriteria?["claude"])
        XCTAssertEqual(laneCriteria?.count, 3)
    }

    // MARK: - response decoding

    func testDecodesChoiceScoreAndNoulAnswers() throws {
        let choiceJSON = """
        {"type":"choice","choice":"technical","probabilities":{"billing":0.159,"technical":0.84},"confidence":0.596}
        """
        let choice = try JSONDecoder().decode(JevAnswer.self, from: Data(choiceJSON.utf8))
        guard case .choice(let picked, let probabilities, let confidence) = choice else {
            return XCTFail("expected choice, got \(choice)")
        }
        XCTAssertEqual(picked, "technical")
        XCTAssertEqual(probabilities["billing"] ?? 0, 0.159, accuracy: 0.0001)
        XCTAssertEqual(probabilities["technical"] ?? 0, 0.84, accuracy: 0.0001)
        XCTAssertEqual(confidence, 0.596, accuracy: 0.0001)

        let scoreJSON = """
        {"type":"score","score":1.035,"legend":{"0":"Calm","1":"Frustrated"},"probabilities":{"0":0.05,"1":0.3},"confidence":0.842}
        """
        let score = try JSONDecoder().decode(JevAnswer.self, from: Data(scoreJSON.utf8))
        guard case .score(let value, let legend, let scoreProbs, let scoreConf) = score else {
            return XCTFail("expected score, got \(score)")
        }
        XCTAssertEqual(value, 1.035, accuracy: 0.0001)
        XCTAssertEqual(legend["0"], "Calm")
        XCTAssertEqual(legend["1"], "Frustrated")
        XCTAssertEqual(scoreProbs["0"] ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(scoreProbs["1"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(scoreConf, 0.842, accuracy: 0.0001)

        let noulJSON = """
        {"type":"noul","noul":0.999}
        """
        let noul = try JSONDecoder().decode(JevAnswer.self, from: Data(noulJSON.utf8))
        guard case .noul(let n) = noul else {
            return XCTFail("expected noul, got \(noul)")
        }
        XCTAssertEqual(n, 0.999, accuracy: 0.0001)

        let responseJSON = """
        {"model":"jev-latest","answers":{"kind":\(choiceJSON),"urgency":\(scoreJSON),"ok":\(noulJSON)},"usage":{"input_tokens":12,"output_tokens":4}}
        """
        let response = try JSONDecoder().decode(JevResponse.self, from: Data(responseJSON.utf8))
        XCTAssertEqual(response.model, "jev-latest")
        XCTAssertEqual(response.answers.count, 3)
        XCTAssertEqual(response.usage?.inputTokens, 12)
        XCTAssertEqual(response.usage?.outputTokens, 4)
    }

    // MARK: - gating

    func testHighConfidenceAgentAppliesLaneRepoAndList() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("agent", confidence: 0.91),
            "lane": Self.choice("cursor", confidence: 0.88),
            "repo": Self.choice("apple-mcp", confidence: 0.85),
            "list": Self.choice("Work", confidence: 0.8)
        ])
        XCTAssertEqual(classifications.count, 1)
        let c = classifications[0]
        XCTAssertEqual(c.id, "t1")
        XCTAssertEqual(c.kind, "agent")
        XCTAssertEqual(c.tags, ["cursor", "apple-mcp"])
        XCTAssertEqual(c.list, "Work")
        XCTAssertEqual(c.confidence ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertNil(c.skipReason)
    }

    func testMediumConfidenceAppliesKindOnly() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("agent", confidence: 0.5),
            "lane": Self.choice("cursor", confidence: 0.9),
            "repo": Self.choice("apple-mcp", confidence: 0.9),
            "list": Self.choice("Work", confidence: 0.9)
        ])
        let c = classifications[0]
        XCTAssertEqual(c.kind, "agent")
        XCTAssertEqual(c.tags, [])
        XCTAssertNil(c.list)
        XCTAssertEqual(c.confidence ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertNil(c.skipReason)
    }

    func testLowConfidenceSetsSkipReason() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("personal", confidence: 0.2),
            "lane": Self.choice("cursor", confidence: 0.9)
        ])
        let c = classifications[0]
        XCTAssertEqual(c.kind, "personal")
        XCTAssertEqual(c.tags, [])
        XCTAssertNil(c.list)
        XCTAssertEqual(c.confidence ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(c.skipReason, "low confidence 0.20 < 0.45 — left for a human")
    }

    func testNoneChoicesAndSubThresholdLaneAreDropped() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("agent", confidence: 0.95),
            "lane": Self.choice("cursor", confidence: 0.5),
            "repo": Self.choice("none", confidence: 0.99),
            "list": Self.choice("none", confidence: 0.99)
        ])
        let c = classifications[0]
        XCTAssertEqual(c.kind, "agent")
        XCTAssertEqual(c.tags, [])
        XCTAssertNil(c.list)
        XCTAssertNil(c.skipReason)
    }

    func testUnknownOptionMapsToNone() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("agent", confidence: 0.95),
            "lane": Self.choice("not-a-lane", confidence: 0.99),
            "repo": Self.choice("APPLE-MCP", confidence: 0.9),
            "list": Self.choice("work", confidence: 0.9)
        ])
        let c = classifications[0]
        XCTAssertEqual(c.tags, ["apple-mcp"])
        XCTAssertEqual(c.list, "Work")
    }

    // MARK: - criteria + signals

    func testCriteriaUsesDescriptionsAndRepoPathFallback() async throws {
        let envName = "JEV_TEST_KEY_CRITERIA"
        setenv(envName, "k", 1)
        defer { unsetenv(envName) }

        let captured = Box<URLRequest?>(nil)
        let transport: JevClient.Transport = { request in
            captured.value = request
            return (Self.okJSON(answers: ["kind": Self.choice("agent", confidence: 0.9)]), 200)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])

        let cursorDesc = "General coding agent for repo work in a git worktree"
        let homeLabDesc = "Docker compose home lab: Home Assistant and services"
        let applePath = "/Users/me/Code/apple-mcp"

        _ = try await JevClassifier.classify(
            items: [["id": "1", "title": "fix the build", "notes": ""]],
            agents: ["cursor", "claude"],
            workdirs: ["apple-mcp", "home-lab"],
            planLists: ["Work"],
            config: config,
            client: client,
            laneDescriptions: ["cursor": cursorDesc],
            repoDescriptions: ["home-lab": homeLabDesc],
            workdirPaths: ["apple-mcp": applePath, "home-lab": "~/Documents/home-lab"])

        guard let body = captured.value?.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let questions = json["questions"] as? [String: Any] else {
            return XCTFail("request body was not a JSON object")
        }

        let laneCriteria = (questions["lane"] as? [String: Any])?["criteria"] as? [String: Any]
        XCTAssertEqual(laneCriteria?["cursor"] as? String, cursorDesc)
        XCTAssertEqual(laneCriteria?["claude"] as? String, "the 'claude' agent lane")

        let repoCriteria = (questions["repo"] as? [String: Any])?["criteria"] as? [String: Any]
        XCTAssertEqual(repoCriteria?["home-lab"] as? String, homeLabDesc)
        let appleText = repoCriteria?["apple-mcp"] as? String
        XCTAssertEqual(appleText, "the 'apple-mcp' repo (working directory apple-mcp: \(applePath))")
        XCTAssertTrue(appleText?.contains(applePath) == true, appleText ?? "nil")

        let listObj = questions["list"] as? [String: Any]
        let listCriteria = listObj?["criteria"] as? NSDictionary
        XCTAssertTrue(listCriteria?["Work"] is NSNull, "plan list names stay null-description, got \(listCriteria?["Work"] as Any)")
    }

    func testSignalsSummarizesFullResponse() async throws {
        let classifications = try await classifyStub(answers: [
            "kind": Self.choice("agent", confidence: 0.78),
            "lane": Self.choice("cursor", confidence: 0.41),
            "repo": Self.choice("apple-mcp", confidence: 0.62),
            "list": Self.choice("none", confidence: 0.55)
        ])
        XCTAssertEqual(
            classifications[0].signals,
            "kind agent 0.78 · lane cursor 0.41 · repo apple-mcp 0.62 · list none 0.55")
    }

    func testSignalsKindOnlyResponse() async throws {
        let envName = "JEV_TEST_KEY_SIGNALS_KIND"
        setenv(envName, "k", 1)
        defer { unsetenv(envName) }
        let transport: JevClient.Transport = { _ in
            (Self.okJSON(answers: ["kind": Self.choice("agent", confidence: 0.91)]), 200)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])
        let classifications = try await JevClassifier.classify(
            items: [["id": "t1", "title": "ship it", "notes": ""]],
            agents: [],
            workdirs: [],
            planLists: [],
            config: config,
            client: client)
        XCTAssertEqual(classifications[0].signals, "kind agent 0.91")
    }

    // MARK: - retry / errors / status

    func testRetries429ThenSucceeds() async throws {
        let envName = "JEV_TEST_KEY_RETRY_OK"
        setenv(envName, "k", 1)
        defer { unsetenv(envName) }

        let calls = Counter()
        let transport: JevClient.Transport = { _ in
            let n = calls.increment()
            if n < 3 {
                return (Data("rate limited".utf8), 429)
            }
            return (Self.okJSON(answers: ["kind": Self.choice("agent", confidence: 0.9)]), 200)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])
        let response = try await client.systemOne(
            state: .text("hello"),
            questions: ["kind": .choice(instructions: "x", criteria: ["a": "b"])])
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(response.answers["kind"]?.choicePayload?.choice, "agent")
    }

    func testFour429sThrowAutomationFailed() async throws {
        let envName = "JEV_TEST_KEY_RETRY_FAIL"
        setenv(envName, "k", 1)
        defer { unsetenv(envName) }

        let calls = Counter()
        let transport: JevClient.Transport = { _ in
            _ = calls.increment()
            return (Data("slow down".utf8), 429)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])
        do {
            _ = try await client.systemOne(
                state: .text("hello"),
                questions: ["kind": .choice(instructions: "x", criteria: ["a": "b"])])
            XCTFail("expected automationFailed")
        } catch AppleTasksError.automationFailed(let why) {
            XCTAssertTrue(why.contains("returned 429"), why)
            XCTAssertTrue(why.hasPrefix("jev:"), why)
            XCTAssertEqual(calls.value, 4)
        } catch {
            XCTFail("expected automationFailed, got \(error)")
        }
    }

    func testMissingApiKeyThrowsInvalidInput() async throws {
        let envName = "JEV_TEST_KEY_MISSING_NEVER_SET"
        unsetenv(envName)
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: { _ in (Data(), 200) }, retryDelays: [])
        do {
            _ = try await client.systemOne(
                state: .text("hello"),
                questions: ["kind": .choice(instructions: "x", criteria: ["a": "b"])])
            XCTFail("expected invalidInput")
        } catch AppleTasksError.invalidInput(let why) {
            XCTAssertTrue(why.contains("jev: api key env var '\(envName)' is unset"), why)
            XCTAssertTrue(why.contains("https://console.typesafe.ai"), why)
        } catch {
            XCTFail("expected invalidInput, got \(error)")
        }
    }

    func testStatusWithAndWithoutEnvKey() {
        let envName = "JEV_TEST_KEY_STATUS"
        unsetenv(envName)
        var config = JevConfig()
        config.apiKeyEnv = envName
        config.model = "jev-latest"
        XCTAssertEqual(
            JevClassifier.status(config: config),
            "no API key in env \(envName) — set it to enable triage --agent jev")

        setenv(envName, "present", 1)
        defer { unsetenv(envName) }
        XCTAssertEqual(
            JevClassifier.status(config: config),
            "configured (key in \(envName), model jev-latest)")
    }

    // MARK: - helpers

    private func classifyStub(answers: [String: [String: Any]]) async throws -> [Triage.Classification] {
        let envName = "JEV_TEST_KEY_CLASSIFY"
        setenv(envName, "k", 1)
        defer { unsetenv(envName) }
        let transport: JevClient.Transport = { _ in
            (Self.okJSON(answers: answers), 200)
        }
        var config = JevConfig()
        config.apiKeyEnv = envName
        let client = JevClient(config: config, transport: transport, retryDelays: [])
        return try await JevClassifier.classify(
            items: [["id": "t1", "title": "ship it", "notes": ""]],
            agents: ["cursor", "claude"],
            workdirs: ["apple-mcp"],
            planLists: ["Work"],
            config: config,
            client: client)
    }

    private static func choice(_ value: String, confidence: Double) -> [String: Any] {
        ["type": "choice", "choice": value,
         "probabilities": [value: confidence], "confidence": confidence]
    }

    private static func okJSON(answers: [String: [String: Any]]) -> Data {
        let body: [String: Any] = [
            "model": "jev-latest",
            "answers": answers,
            "usage": ["input_tokens": 1, "output_tokens": 1]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}
