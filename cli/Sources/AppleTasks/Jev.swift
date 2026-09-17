import Foundation

// TypeSafe Jev ("System One"): POST a state plus typed questions, get typed
// answers — no text generation. The `jev` classifier seat uses that for
// inbox triage (`apple-tasks triage --agent jev`). Same contract as every
// other seat: this module only judges; Triage applies and audits mutations.

// MARK: - agents.json `jev` block

struct JevConfig: Codable, Equatable, Sendable {
    /// Env var holding the API key (default `TYPESAFE_API_KEY`).
    var apiKeyEnv: String?
    /// System One endpoint (default `https://api.typesafe.ai/v1/systemone`).
    var endpoint: String?
    /// Model id (default `jev-latest`).
    var model: String?
    /// At/above this `kind` confidence, apply the full classification (default 0.7).
    var applyConfidence: Double?
    /// At/above this (but below apply), apply `kind` only (default 0.45).
    var reviewConfidence: Double?
    /// HTTP timeout in seconds (default 30).
    var timeoutSeconds: Double?

    static let defaultApiKeyEnv = "TYPESAFE_API_KEY"
    static let defaultEndpoint = "https://api.typesafe.ai/v1/systemone"
    static let defaultModel = "jev-latest"
    static let defaultApplyConfidence = 0.7
    static let defaultReviewConfidence = 0.45
    static let defaultTimeoutSeconds = 30.0

    var resolvedApiKeyEnv: String { nonEmpty(apiKeyEnv) ?? Self.defaultApiKeyEnv }
    var resolvedEndpoint: String { nonEmpty(endpoint) ?? Self.defaultEndpoint }
    var resolvedModel: String { nonEmpty(model) ?? Self.defaultModel }
    var resolvedApplyConfidence: Double { applyConfidence ?? Self.defaultApplyConfidence }
    var resolvedReviewConfidence: Double { reviewConfidence ?? Self.defaultReviewConfidence }
    var resolvedTimeoutSeconds: Double { timeoutSeconds ?? Self.defaultTimeoutSeconds }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - request / response

/// `state` is either a plain string or a JSON object of string fields.
enum JevState: Encodable, Equatable, Sendable {
    case text(String)
    case object([String: String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .object(let object):
            try container.encode(object)
        }
    }
}

/// Typed System One question. Criteria shape depends on `type`.
enum JevQuestion: Encodable, Equatable, Sendable {
    /// Choice criteria maps option key → description (or `null`).
    case choice(instructions: String, criteria: [String: String?])
    /// Score criteria is an ordered list of level descriptions (≥2).
    case score(instructions: String, criteria: [String])
    /// Noul (true/false) criteria is optional.
    case noul(instructions: String, criteria: NoulCriteria? = nil)

    struct NoulCriteria: Encodable, Equatable, Sendable {
        var `true`: String
        var `false`: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let instructions, let criteria):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(NullValueObject(criteria), forKey: .criteria)
        case .score(let instructions, let criteria):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case .noul(let instructions, let criteria):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            if let criteria {
                try container.encode(criteria, forKey: .criteria)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }
}

/// JSONEncoder skips nil values in `[String: String?]`; System One wants explicit `null`.
private struct NullValueObject: Encodable {
    let values: [String: String?]
    init(_ values: [String: String?]) { self.values = values }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in values {
            let codingKey = AnyCodingKey(key)
            if let value {
                try container.encode(value, forKey: codingKey)
            } else {
                try container.encodeNil(forKey: codingKey)
            }
        }
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

enum JevAnswer: Decodable, Equatable, Sendable {
    case choice(choice: String, probabilities: [String: Double], confidence: Double)
    case score(score: Double, legend: [String: String], probabilities: [String: Double], confidence: Double)
    case noul(noul: Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "choice":
            self = .choice(
                choice: try container.decode(String.self, forKey: .choice),
                probabilities: try container.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:],
                confidence: try container.decode(Double.self, forKey: .confidence)
            )
        case "score":
            self = .score(
                score: try container.decode(Double.self, forKey: .score),
                legend: try container.decodeIfPresent([String: String].self, forKey: .legend) ?? [:],
                probabilities: try container.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:],
                confidence: try container.decode(Double.self, forKey: .confidence)
            )
        case "noul":
            self = .noul(noul: try container.decode(Double.self, forKey: .noul))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown Jev answer type '\(type)'")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, choice, probabilities, confidence, score, legend, noul
    }

    var choicePayload: (choice: String, confidence: Double)? {
        if case .choice(let choice, _, let confidence) = self { return (choice, confidence) }
        return nil
    }
}

struct JevResponse: Decodable, Equatable, Sendable {
    var model: String
    var answers: [String: JevAnswer]
    var usage: Usage?

    struct Usage: Decodable, Equatable, Sendable {
        var inputTokens: Int
        var outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

private struct JevRequestBody: Encodable {
    let state: JevState
    let model: String
    let questions: [String: JevQuestion]
}

// MARK: - HTTP client

struct JevClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let config: JevConfig
    private let transport: Transport
    /// Backoff before retry 1, 2, 3 (default 0.5s, 1s, 2s). Empty skips sleeps
    /// (tests) but still retries 429/529 up to 3 times.
    private let retryDelays: [Double]

    init(config: JevConfig?, transport: Transport? = nil, retryDelays: [Double] = [0.5, 1, 2]) {
        self.config = config ?? JevConfig()
        self.retryDelays = retryDelays
        if let transport {
            self.transport = transport
        } else {
            self.transport = { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (data, status)
            }
        }
    }

    func systemOne(state: JevState, questions: [String: JevQuestion]) async throws -> JevResponse {
        let envName = config.resolvedApiKeyEnv
        guard let key = jevReadEnv(envName), !key.isEmpty else {
            throw AppleTasksError.invalidInput(
                "jev: api key env var '\(envName)' is unset — get a key at https://console.typesafe.ai and export it (launchd: ~/.config/apple-tasks/launchd.env)")
        }
        guard let url = URL(string: config.resolvedEndpoint) else {
            throw AppleTasksError.invalidInput("jev: bad endpoint URL: \(config.resolvedEndpoint)")
        }

        var request = URLRequest(url: url, timeoutInterval: config.resolvedTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            JevRequestBody(state: state, model: config.resolvedModel, questions: questions))

        let host = url.host ?? config.resolvedEndpoint
        let maxRetries = 3
        var attempt = 0
        while true {
            let (data, status) = try await transport(request)
            if status == 200 {
                do {
                    return try JSONDecoder().decode(JevResponse.self, from: data)
                } catch {
                    let snippet = (String(data: data, encoding: .utf8) ?? "").prefix(300)
                    throw AppleTasksError.automationFailed(
                        "jev: unexpected response shape: \(error) \(snippet)")
                }
            }
            let retryable = status == 429 || status == 529
            if retryable, attempt < maxRetries {
                let delay = attempt < retryDelays.count ? retryDelays[attempt] : 0
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                attempt += 1
                continue
            }
            let snippet = (String(data: data, encoding: .utf8) ?? "").prefix(300)
            throw AppleTasksError.automationFailed("jev: \(host) returned \(status): \(snippet)")
        }
    }
}

// MARK: - classifier seat

enum JevClassifier {
    /// Reserved `--agent` value that selects the Jev seat.
    static let agentTag = "jev"

    /// Doctor line. No network.
    static func status(config: JevConfig?) -> String {
        let cfg = config ?? JevConfig()
        let envName = cfg.resolvedApiKeyEnv
        let model = cfg.resolvedModel
        if let key = jevReadEnv(envName), !key.isEmpty {
            return "configured (key in \(envName), model \(model))"
        }
        return "no API key in env \(envName) — set it to enable triage --agent jev"
    }

    static func classify(items: [[String: String]], agents: [String], workdirs: [String],
                         planLists: [String], config: JevConfig?,
                         client: JevClient? = nil) async throws -> [Triage.Classification] {
        let cfg = config ?? JevConfig()
        let client = client ?? JevClient(config: cfg)
        let questions = Self.questions(agents: agents, workdirs: workdirs, planLists: planLists)
        let apply = cfg.resolvedApplyConfidence
        let review = cfg.resolvedReviewConfidence

        if items.isEmpty { return [] }

        var results = [Triage.Classification?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, Triage.Classification).self) { group in
            var next = 0
            let initial = min(4, items.count)
            while next < initial {
                let index = next
                next += 1
                group.addTask {
                    let classification = try await Self.classifyOne(
                        item: items[index], questions: questions,
                        agents: agents, workdirs: workdirs, planLists: planLists,
                        apply: apply, review: review, client: client)
                    return (index, classification)
                }
            }
            for try await (index, classification) in group {
                results[index] = classification
                if next < items.count {
                    let queued = next
                    next += 1
                    group.addTask {
                        let classification = try await Self.classifyOne(
                            item: items[queued], questions: questions,
                            agents: agents, workdirs: workdirs, planLists: planLists,
                            apply: apply, review: review, client: client)
                        return (queued, classification)
                    }
                }
            }
        }
        return results.map { $0! }
    }

    private static func classifyOne(item: [String: String], questions: [String: JevQuestion],
                                    agents: [String], workdirs: [String], planLists: [String],
                                    apply: Double, review: Double,
                                    client: JevClient) async throws -> Triage.Classification {
        let id = item["id"] ?? ""
        let title = item["title"] ?? ""
        let notes = item["notes"] ?? ""
        let response = try await client.systemOne(
            state: .object(["title": title, "notes": notes]),
            questions: questions)

        guard let kindAnswer = response.answers["kind"],
              let kind = kindAnswer.choicePayload else {
            throw AppleTasksError.automationFailed("jev: missing or non-choice 'kind' answer")
        }
        let kindValue = canonical(kind.choice, in: ["agent", "personal"]) ?? kind.choice
        let confidence = kind.confidence

        if confidence < review {
            return Triage.Classification(
                id: id, kind: kindValue, tags: [], list: nil,
                confidence: confidence,
                skipReason: String(format: "low confidence %.2f < %.2f — left for a human",
                                   confidence, review))
        }
        if confidence < apply {
            return Triage.Classification(
                id: id, kind: kindValue, tags: [], list: nil,
                confidence: confidence, skipReason: nil)
        }

        guard kindValue == "agent" else {
            return Triage.Classification(
                id: id, kind: kindValue, tags: [], list: nil,
                confidence: confidence, skipReason: nil)
        }

        var tags: [String] = []
        if let lane = acceptedChoice(response.answers["lane"], allowed: agents, floor: apply) {
            tags.append(lane)
        }
        if let repo = acceptedChoice(response.answers["repo"], allowed: workdirs, floor: apply) {
            tags.append(repo)
        }
        let list = acceptedChoice(response.answers["list"], allowed: planLists, floor: apply)
        return Triage.Classification(
            id: id, kind: kindValue, tags: tags, list: list,
            confidence: confidence, skipReason: nil)
    }

    private static func questions(agents: [String], workdirs: [String],
                                  planLists: [String]) -> [String: JevQuestion] {
        var questions: [String: JevQuestion] = [
            "kind": .choice(
                instructions: "Is this reminder actionable software/repo work that an AI coding agent could do, or a personal item?",
                criteria: [
                    "agent": "actionable software, repo, automation, or home-lab work an AI coding agent could do",
                    "personal": "errands, appointments, finances, shopping, health — anything not software work"
                ])
        ]
        if !agents.isEmpty {
            var criteria: [String: String?] = [
                "none": "not agent work, or no lane clearly fits"
            ]
            for tag in agents { criteria[tag] = "the '\(tag)' agent lane" }
            questions["lane"] = .choice(
                instructions: "If this is agent work, which agent lane should run it?",
                criteria: criteria)
        }
        if !workdirs.isEmpty {
            var criteria: [String: String?] = [
                "none": "no specific repo"
            ]
            for tag in workdirs { criteria[tag] = "the '\(tag)' repo" }
            questions["repo"] = .choice(
                instructions: "Which repo or project does this concern?",
                criteria: criteria)
        }
        if !planLists.isEmpty {
            var criteria: [String: String?] = [
                "none": "none of these lists fits"
            ]
            for name in planLists { criteria[name] = nil }
            questions["list"] = .choice(
                instructions: "Which plan list should this task move to?",
                criteria: criteria)
        }
        return questions
    }

    /// Match Jev's option string back to a canonical value from `allowed`.
    /// `"none"` and anything not in the set are dropped.
    private static func acceptedChoice(_ answer: JevAnswer?, allowed: [String],
                                       floor: Double) -> String? {
        guard let payload = answer?.choicePayload, payload.confidence >= floor else { return nil }
        if payload.choice.caseInsensitiveCompare("none") == .orderedSame { return nil }
        return canonical(payload.choice, in: allowed)
    }

    private static func canonical(_ raw: String, in allowed: [String]) -> String? {
        allowed.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }
}

/// `ProcessInfo.environment` is cached on first read; `getenv` sees `setenv` in tests.
private func jevReadEnv(_ name: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
        return value
    }
    guard let raw = getenv(name) else { return nil }
    let value = String(cString: raw)
    return value.isEmpty ? nil : value
}
