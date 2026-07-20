# Claude as a FoundationModels `LanguageModel` — SDK spelunk (beta 3, 26A5378j)

Findings from reading `FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
in the Xcode 27 beta 3 SDK (27A5194q). Everything below is **public API**, new in
the 27.0 availability band — this is the pluggable-provider seam the
"Claude for Apple Foundation Models" package builds on.

## The seam

`LanguageModelSession` (26.0) gained 27.0 initializers that accept ANY model:

```swift
convenience init(model: some LanguageModel, tools: [any Tool] = [], instructions: Instructions? = nil)
convenience init(model: some LanguageModel, tools: [any Tool] = [], transcript: Transcript)
```

So the entire session machinery — `Tool` calling, `@Generable` guided
generation, transcripts, streaming — runs unchanged on a third-party backend.
Apple ships two conformers: `SystemLanguageModel` (on-device) and
`PrivateCloudComputeLanguageModel`. A Claude provider is a third.

## What a provider implements

Two protocols, both public, both `Sendable`:

```swift
public protocol LanguageModel: Sendable {
  associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
  var capabilities: LanguageModelCapabilities { get }        // .vision, .guidedGeneration, .reasoning, .toolCalling
  var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
  associatedtype Configuration: Hashable, Sendable
  associatedtype Model: LanguageModel
  init(configuration: Configuration) throws
  func prewarm(model: Model, transcript: Transcript)          // default impl provided
  nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
```

### The request (everything needed to build a Messages API call)

```swift
struct LanguageModelExecutorGenerationRequest: Sendable {
  var id: UUID
  var transcript: Transcript                                  // full conversation → messages[]
  var enabledToolDefinitions: [Transcript.ToolDefinition]     // → tools[]
  var schema: GenerationSchema?                               // guided generation → tool-forced JSON or output_format
  var generationOptions: GenerationOptions                    // temperature, toolCallingMode, …
  var contextOptions: ContextOptions
  var metadata: [String: any Sendable & Codable & Equatable]
}
```

### The channel (maps 1:1 onto Anthropic SSE stream events)

`LanguageModelExecutorGenerationChannel` is an `AsyncSequence` of events with a
`send(_ event: some Event)` method. Event factories:

- `.response(entryID:action:)` — `.appendText(TextFragment)`,
  `.replaceTextSegment`, `.updateUsage`, `.updateMetadata`, attachment segments
- `.reasoning(entryID:action:)` — `.appendText`, `.updateSignature(Data, tokenCount:)`
  ← thinking blocks + signature, purpose-built for Claude extended thinking
- `.toolCalls(entryID:action:)` — `.toolCall(...)` / `.removeToolCall(id:)`;
  each ToolCall has `.appendArguments(ArgumentsFragment)` for streamed
  partial-JSON tool inputs

`Usage` carries `input.totalTokenCount` / `input.cachedTokenCount` and
`output.totalTokenCount` / `output.reasoningTokenCount` — cache-aware, thinking-aware.

### Error taxonomy (throw from `respond`)

`LanguageModelError`: `.contextSizeExceeded(contextSize:tokenCount:)`,
`.rateLimited(resetDate:)`, `.guardrailViolation`, `.refusal`,
`.unsupportedCapability`, `.unsupportedTranscriptContent([Transcript.Entry])`,
`.unsupportedGenerationGuide(schemaName:)`, `.unsupportedLanguageOrLocale`,
`.timeout`. All carry `metadata: [String: any Sendable]`. Maps cleanly from
Anthropic API errors (429 → `.rateLimited` with `resetDate` from headers, etc.).

## Sketch: `ClaudeLanguageModel`

```swift
struct ClaudeLanguageModel: LanguageModel {
  typealias Executor = ClaudeExecutor
  var modelID = "claude-fable-5"           // or claude-sonnet-5 for dispatch workloads
  var capabilities: LanguageModelCapabilities {
    .init(capabilities: [.toolCalling, .reasoning, .vision, .guidedGeneration])
  }
  var executorConfiguration: ClaudeExecutor.Configuration { .init(modelID: modelID) }
}

struct ClaudeExecutor: LanguageModelExecutor {
  struct Configuration: Hashable, Sendable { var modelID: String }  // key from Keychain, NOT config
  init(configuration: Configuration) throws { … }
  func respond(to request: …, model: ClaudeLanguageModel, streamingInto channel: …) async throws {
    // 1. Transcript.entries → messages[] (instructions entry → system prompt)
    // 2. enabledToolDefinitions → tools[] (GenerationSchema → JSON Schema)
    // 3. POST /v1/messages stream:true; translate SSE:
    //    content_block_delta(text_delta)      → channel.send(.response(action: .appendText(…)))
    //    content_block_delta(thinking_delta)  → channel.send(.reasoning(action: .appendText(…)))
    //    signature_delta                      → .reasoning(.updateSignature(…))
    //    content_block_start(tool_use) + input_json_delta
    //                                         → .toolCalls(.toolCall(… .appendArguments …))
    //    message_delta.usage                  → .updateUsage(input:output:)
  }
}
```

Open questions for the build:
- `Transcript.Entry` / `Transcript.Segment` enumeration → exact mapping table
  (instructions, prompt, response, toolCalls, toolOutput cases).
- `GenerationSchema` → JSON Schema serialization: it's `Codable` — check whether
  its encoded form is already JSON Schema (it was for the App Intents work).
- guided generation: prefer a forced tool call (`tool_choice: {type: "tool"}`)
  over prompt-based JSON for `schema != nil`.
- The upstream "Claude for Apple Foundation Models" package (memory: exists as
  of Jun 2026) may already do all of this — evaluate adopting it vs. the ~300-line
  hand-rolled executor above. Hand-rolled keeps the AgentTasks audit hooks easy
  (usage events → AuditDB).

## Status

`research/ClaudeLanguageModel/ClaudeLanguageModel.swift` typechecks clean against
the beta 3 SDK (`swiftc -typecheck -target arm64-apple-macos27.0`): full
`LanguageModel` + `LanguageModelExecutor` conformance with transcript folding
(alternating-role coalescing incl. thinking-signature replay), SSE → channel
event translation, and Anthropic error mapping. Not yet exercised live.

**Resolved**: `GenerationSchema`'s `Codable` encoding IS standard JSON Schema
(verified via `SchemaProbe.swift` on beta 3: `type`/`properties`/`required`,
`@Guide` descriptions and `.range` → `minimum`/`maximum`, plus harmless
`title`/`x-order` extras). The executor's `input_schema` encoding works as-is.

**Blocked (docs/roadmap.md #33)**: the live round-trip harness (`Harness.swift`,
compiles clean) dies in dyld — the beta 3 OS runtime ships a newer
FoundationModels than SDK 27A5194q declares. `…GenerationChannel.Event` is a
protocol in the SDK but a concrete struct at runtime, so `channel.send` can't
bind; `LanguageModelError.Refusal.init` also changed (worked around with a
custom `ClaudeAPIError` for generic HTTP failures). Re-attempt when the next
Xcode beta drops; expect a small mechanical diff on the event factories.
Also still needs `ANTHROPIC_API_KEY` (absent from env and keychain). Then:
guided generation + vision.

## Why this matters for apple-mcp

`AgentTasksApp` already exposes TaskEntity/intents. A `LanguageModelSession`
constructed with `ClaudeLanguageModel` + `Tool` wrappers around the apple-tasks
CLI verbs = an in-process Claude agent with native Reminders/Calendar/Notes
tools, no MCP hop, streaming into SwiftUI. This is docs/roadmap.md's Foundation Models
integration idea, now confirmed buildable on public API.
