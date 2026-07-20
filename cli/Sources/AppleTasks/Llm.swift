import ArgumentParser
import Foundation

// DIY / bring-your-own model (IDEAS #51): a dumb bridge from a prompt to any
// OpenAI-compatible chat-completions endpoint (ollama, LM Studio, llama.cpp,
// vLLM, LiteLLM, OpenRouter, …). No tools, no state — it prints the model's
// reply and exits. That makes it a drop-in agents.json command for
// classifier seats (triage) and generate-only dispatch lanes.

struct LlmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm",
        abstract: """
        Send one prompt to an OpenAI-compatible endpoint and print the reply. \
        Profiles live in ~/.config/apple-tasks/llm.json; flags override. \
        Plain completion only — no tool use, no conversation state.
        """
    )

    @Option(name: [.customShort("p"), .customLong("prompt")],
            help: "The prompt. Omit to read it from stdin.")
    var prompt: String?

    @Option(help: "Agent tag from agents.json whose \"llm\" block is the profile — how BYOM dispatch lanes invoke this. Wins over --profile.")
    var agent: String?

    @Option(help: "Profile name from llm.json (default: the file's \"default\", else flags only).")
    var profile: String?

    @Option(help: "Endpoint base URL, e.g. http://mini.local:11434/v1 ('/chat/completions' appended if missing).")
    var endpoint: String?

    @Option(help: "Model name as the endpoint knows it.")
    var model: String?

    @Option(name: .customLong("api-key-env"), help: "Environment variable holding the API key.")
    var apiKeyEnv: String?

    @Option(help: "System prompt.")
    var system: String?

    @Option(name: .customLong("max-tokens"), help: "Completion token cap (default: endpoint's default).")
    var maxTokens: Int?

    @Option(help: "Sampling temperature (default: endpoint's default).")
    var temperature: Double?

    @Option(name: .customLong("timeout"), help: "Request timeout in seconds (default 120).")
    var timeoutSeconds: Double = 120

    struct Profile: Codable {
        var endpoint: String?
        var model: String?
        /// Literal key. Prefer apiKeyEnv; if you inline one, keep llm.json chmod 600.
        var apiKey: String?
        /// Name of an environment variable holding the key (wins over apiKey).
        var apiKeyEnv: String?
        var system: String?
        var maxTokens: Int?
        var temperature: Double?
    }

    struct ConfigFile: Codable {
        /// Profile used when --profile is not passed.
        var `default`: String?
        var profiles: [String: Profile]
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/llm.json")
    }

    func run() async throws {
        var base = Profile()
        if let agent {
            let config = try AgentsConfig.load()
            guard let lane = config.agents[agent.lowercased()], let llm = lane.llm else {
                throw AppleTasksError.invalidInput(
                    "no agent '\(agent)' with an \"llm\" block in \(AgentsConfig.url.path)")
            }
            base = llm
        } else if let data = try? Data(contentsOf: Self.configURL) {
            let file: ConfigFile
            do {
                file = try JSONDecoder().decode(ConfigFile.self, from: data)
            } catch {
                throw AppleTasksError.invalidInput("could not parse \(Self.configURL.path): \(error)")
            }
            if let name = profile ?? file.default {
                guard let found = file.profiles[name] else {
                    throw AppleTasksError.invalidInput(
                        "no '\(name)' profile in llm.json (have: \(file.profiles.keys.sorted().joined(separator: ", ")))")
                }
                base = found
            }
        } else if let profile {
            throw AppleTasksError.invalidInput(
                "--profile \(profile) given but no config at \(Self.configURL.path)")
        }

        guard let endpointRaw = endpoint ?? base.endpoint else {
            throw AppleTasksError.invalidInput("""
            no endpoint — pass --endpoint or create \(Self.configURL.path), e.g. \
            {"default": "local", "profiles": {"local": {"endpoint": \
            "http://localhost:11434/v1", "model": "qwen3", "apiKeyEnv": "MY_LLM_KEY"}}}
            """)
        }
        guard let model = model ?? base.model else {
            throw AppleTasksError.invalidInput("no model — pass --model or set it in the profile")
        }

        var promptText = prompt
        if promptText == nil {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            promptText = String(data: data, encoding: .utf8)
        }
        guard let promptText, !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleTasksError.invalidInput("no prompt — pass -p or pipe it on stdin")
        }

        var key: String?
        if let envName = apiKeyEnv ?? base.apiKeyEnv {
            guard let fromEnv = ProcessInfo.processInfo.environment[envName], !fromEnv.isEmpty else {
                throw AppleTasksError.invalidInput("api key env var '\(envName)' is unset")
            }
            key = fromEnv
        } else {
            key = base.apiKey
        }

        var urlString = endpointRaw.hasSuffix("/") ? String(endpointRaw.dropLast()) : endpointRaw
        if !urlString.hasSuffix("/chat/completions") {
            urlString += "/chat/completions"
        }
        guard let url = URL(string: urlString) else {
            throw AppleTasksError.invalidInput("bad endpoint URL: \(urlString)")
        }

        var messages: [[String: String]] = []
        if let system = system ?? base.system {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": promptText])
        var payload: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if let maxTokens = maxTokens ?? base.maxTokens { payload["max_tokens"] = maxTokens }
        if let temperature = temperature ?? base.temperature { payload["temperature"] = temperature }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AppleTasksError.automationFailed(
                "\(url.host ?? "endpoint") returned \(status): \((String(data: data, encoding: .utf8) ?? "").prefix(300))")
        }
        struct Completion: Codable {
            struct Choice: Codable {
                struct Message: Codable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content else {
            throw AppleTasksError.automationFailed(
                "unexpected response shape (not OpenAI-compatible?): \((String(data: data, encoding: .utf8) ?? "").prefix(300))")
        }
        print(content)
    }
}
