// Live round-trip harness: LanguageModelSession running on ClaudeLanguageModel
// with one Tool. Requires ANTHROPIC_API_KEY in the environment.
//
// Build: swiftc -parse-as-library -target arm64-apple-macos27.0 \
//          ClaudeLanguageModel.swift Harness.swift -o build/harness
// Run:   ANTHROPIC_API_KEY=... build/harness

import Foundation
import FoundationModels

@available(macOS 27.0, *)
struct ClockTool: Tool {
    let name = "current_time"
    let description = "Returns the current local date and time on this Mac."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        Date().formatted(date: .abbreviated, time: .standard)
    }
}

@main
enum Harness {
    static func main() async {
        guard #available(macOS 27.0, *) else {
            print("needs macOS 27+"); exit(2)
        }
        guard ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil else {
            print("ANTHROPIC_API_KEY not set; cannot run live round-trip"); exit(2)
        }
        do {
            let session = LanguageModelSession(
                model: ClaudeLanguageModel(),
                tools: [ClockTool()],
                instructions: "You are a test harness. Answer in one short sentence.")
            let response = try await session.respond(
                to: "Use the current_time tool, then tell me what time it is.")
            print("RESPONSE: \(response.content)")
            print("TRANSCRIPT ENTRIES: \(session.transcript.count)")
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
}
