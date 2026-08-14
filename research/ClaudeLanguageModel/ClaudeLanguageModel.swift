// ClaudeLanguageModel spike: Claude as a FoundationModels LanguageModel provider.
// See docs/claude-language-model-spike.md for the SDK spelunk this is built from.
//
// Typecheck: swiftc -typecheck -target arm64-apple-macos27.0 ClaudeLanguageModel.swift
// v1 scope: text + tool calling + thinking replay. No vision, no guided generation yet.

import Foundation
import FoundationModels

@available(macOS 27.0, *)
struct ClaudeLanguageModel: LanguageModel {
    typealias Executor = ClaudeExecutor

    var modelID: String = "claude-fable-5"
    var maxTokens: Int = 8192

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    var executorConfiguration: ClaudeExecutor.Configuration {
        .init(modelID: modelID, maxTokens: maxTokens)
    }
}

@available(macOS 27.0, *)
struct ClaudeExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        var modelID: String
        var maxTokens: Int
        var endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 model: ClaudeLanguageModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !apiKey.isEmpty else {
            throw LanguageModelError.unsupportedCapability(.init(
                capability: .toolCalling,
                debugDescription: "ANTHROPIC_API_KEY is not set"))
        }

        let body = try requestBody(for: request)
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelError.timeout(.init(debugDescription: "non-HTTP response"))
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw mapHTTPError(status: http.statusCode, headers: http, body: detail)
        }

        try await streamSSE(bytes, into: channel)
    }

    // MARK: - Transcript -> Messages API

    private func requestBody(for request: LanguageModelExecutorGenerationRequest) throws -> [String: Any] {
        var system = [String]()
        // (side, blocks): fold entries into alternating user/assistant messages.
        var folded = [(role: String, blocks: [[String: Any]])]()

        func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if folded.last?.role == role {
                folded[folded.count - 1].blocks.append(contentsOf: blocks)
            } else {
                folded.append((role, blocks))
            }
        }

        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                system.append(contentsOf: instructions.segments.compactMap(plainText))
            case .prompt(let prompt):
                append(role: "user", blocks: prompt.segments.compactMap(textBlock))
            case .response(let response):
                append(role: "assistant", blocks: response.segments.compactMap(textBlock))
            case .reasoning(let reasoning):
                // Thinking blocks can only be replayed with their signature.
                if let signature = reasoning.signature {
                    let text = reasoning.segments.compactMap(plainText).joined()
                    append(role: "assistant", blocks: [[
                        "type": "thinking",
                        "thinking": text,
                        "signature": signature.base64EncodedString(),
                    ]])
                }
            case .toolCalls(let calls):
                append(role: "assistant", blocks: try calls.map { call in
                    [
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.toolName,
                        "input": try jsonObject(call.arguments.jsonString),
                    ]
                })
            case .toolOutput(let output):
                append(role: "user", blocks: [[
                    "type": "tool_result",
                    "tool_use_id": output.id,
                    "content": output.segments.compactMap(textBlock),
                ]])
            @unknown default:
                throw LanguageModelError.unsupportedTranscriptContent(.init(
                    unsupportedContent: [entry],
                    debugDescription: "unhandled transcript entry kind"))
            }
        }

        var body: [String: Any] = [
            "model": configuration.modelID,
            "max_tokens": configuration.maxTokens,
            "stream": true,
            "messages": folded.map { ["role": $0.role, "content": $0.blocks] },
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    // Open question from the spelunk: GenerationSchema's Codable
                    // encoding is assumed to be JSON Schema. Verify at runtime.
                    "input_schema": try jsonObject(String(
                        data: JSONEncoder().encode(tool.parameters), encoding: .utf8) ?? "{}"),
                ]
            }
        }
        return body
    }

    private func plainText(_ segment: Transcript.Segment) -> String? {
        switch segment {
        case .text(let text): return text.content
        case .structure(let structure): return structure.content.jsonString
        default: return nil
        }
    }

    private func textBlock(_ segment: Transcript.Segment) -> [String: Any]? {
        plainText(segment).map { ["type": "text", "text": $0] }
    }

    private func jsonObject(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    // MARK: - SSE -> channel events

    private func streamSSE(_ bytes: URLSession.AsyncBytes,
                           into channel: LanguageModelExecutorGenerationChannel) async throws {
        // index -> (kind, toolID, toolName) for open content blocks
        var blocks = [Int: (kind: String, toolID: String, toolName: String)]()
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        // The API does not break out thinking tokens in stream usage yet.
        let reasoningTokens = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let event = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    cachedTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                }

            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any],
                      let kind = block["type"] as? String else { continue }
                blocks[index] = (kind,
                                 block["id"] as? String ?? "",
                                 block["name"] as? String ?? "")

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let block = blocks[index],
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                switch deltaType {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    await channel.send(.response(action: .appendText(text, tokenCount: 0)))
                case "thinking_delta":
                    let text = delta["thinking"] as? String ?? ""
                    await channel.send(.reasoning(action: .appendText(text, tokenCount: 0)))
                case "signature_delta":
                    if let signature = delta["signature"] as? String,
                       let data = Data(base64Encoded: signature) {
                        await channel.send(.reasoning(action: .updateSignature(data, tokenCount: 0)))
                    }
                case "input_json_delta":
                    let json = delta["partial_json"] as? String ?? ""
                    await channel.send(.toolCalls(action: .toolCall(
                        id: block.toolID, name: block.toolName,
                        action: .appendArguments(json, tokenCount: 0))))
                default:
                    break
                }

            case "message_delta":
                if let usage = event["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            case "message_stop":
                await channel.send(.response(action: .updateUsage(
                    input: .init(totalTokenCount: inputTokens, cachedTokenCount: cachedTokens),
                    output: .init(totalTokenCount: outputTokens, reasoningTokenCount: reasoningTokens))))

            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                throw LanguageModelError.timeout(.init(debugDescription: message))

            default:
                break
            }
        }

    }

    private func mapHTTPError(status: Int, headers: HTTPURLResponse, body: String) -> any Error {
        switch status {
        case 429:
            let reset = (headers.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                .map { Date(timeIntervalSinceNow: $0) }
            return LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: body))
        case 400 where body.contains("context"):
            return LanguageModelError.contextSizeExceeded(.init(
                contextSize: 0, tokenCount: 0, debugDescription: body))
        default:
            // Beta 3 runtime skew: LanguageModelError.Refusal's SDK initializer
            // no longer exists at runtime (it gained a required `explanation:`
            // param the SDK interface doesn't declare yet). Throw our own type.
            return ClaudeAPIError(status: status, body: body)
        }
    }
}

struct ClaudeAPIError: Error, LocalizedError {
    var status: Int
    var body: String
    var errorDescription: String? { "Anthropic API HTTP \(status): \(body)" }
}
