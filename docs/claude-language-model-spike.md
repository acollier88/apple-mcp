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

`research/ClaudeLanguageModel/ClaudeLanguageModel.swift` builds clean against the
beta 4 SDK (26A5388f, `-target arm64-apple-macos27.0`): full `LanguageModel` +
`LanguageModelExecutor` conformance with transcript folding (alternating-role
coalescing incl. thinking-signature replay), SSE → channel event translation,
and Anthropic error mapping. **Exercised live 2026-08-07** — see below.

**Resolved**: `GenerationSchema`'s `Codable` encoding IS standard JSON Schema
(verified via `SchemaProbe.swift` on beta 3: `type`/`properties`/`required`,
`@Guide` descriptions and `.range` → `minimum`/`maximum`, plus harmless
`title`/`x-order` extras). The executor's `input_schema` encoding works as-is.

**Resolved (docs/roadmap.md #33)**: the live round-trip harness
(`Harness.swift`) was blocked through beta 3 by an SDK/runtime skew —
`…GenerationChannel.Event` was a protocol in SDK 27A5194q but a concrete
struct at runtime, so `channel.send` couldn't bind, and the binary died in
dyld at launch. Beta 4 (OS 26A5388g, Xcode beta 27A5228h, SDK 26A5388f)
healed it with no source changes; the anticipated event-factory diff never
materialized. One deprecation fixed along the way:
`LanguageModelCapabilities(capabilities:)` → `LanguageModelCapabilities(_:)`.
The custom `ClaudeAPIError` for generic HTTP failures stays (it predates and
outlives the `LanguageModelError.Refusal.init` change).

**Verified live 2026-08-07**: `ANTHROPIC_API_KEY=... build/harness` completed
a full round-trip — Claude called `ClockTool`, read the result, and answered
from it; 5 transcript entries (instructions → prompt → toolCalls →
toolOutput → response). Transcript folding, SSE → channel event translation,
and the tool hop are all exercised. Next: guided generation + vision.

Note on credentials: the harness reads `ANTHROPIC_API_KEY` and sends it as
`x-api-key`, so it needs a **Console** API key with credits
(platform.claude.com/settings/keys). A Claude Pro/Max/Team subscription does
not cover API usage, and subscription "usage credits" are a separate balance
that only extends plan usage (web/desktop/Claude Code) — they cannot pay for
api.anthropic.com calls.

## Why this matters for apple-mcp

`AgentTasksApp` already exposes TaskEntity/intents. A `LanguageModelSession`
constructed with `ClaudeLanguageModel` + `Tool` wrappers around the apple-tasks
CLI verbs = an in-process Claude agent with native Reminders/Calendar/Notes
tools, no MCP hop, streaming into SwiftUI. This is docs/roadmap.md's Foundation Models
integration idea, now confirmed buildable on public API.
