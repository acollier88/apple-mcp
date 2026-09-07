import AppIntents
import CoreSpotlight
import Foundation
import FoundationModels

/// On-device Q&A over the donated task index (IDEAS #31 + iOS/macOS 27
/// `SpotlightSearchTool`). The model searches Core Spotlight — it never sees
/// the live Reminders store — so donations must stay fresh.
@available(macOS 27.0, *)
enum AgentQueueAsk {
    static func answer(_ question: String) async throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AgentTasks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Ask a question about the queue."])
        }

        await SpotlightDonation.donateAllOpenTasks()

        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw NSError(domain: "AgentTasks", code: 5,
                          userInfo: [NSLocalizedDescriptionKey:
                            "On-device model unavailable (\(reason)). Turn on Apple Intelligence in System Settings."])
        @unknown default:
            throw NSError(domain: "AgentTasks", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "On-device model unavailable."])
        }

        // Default SpotlightSearchTool schema overflows the on-device context
        // window (FB 183770678). `.focused()` is the compact items-domain guide.
        let tool = SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight],
            guide: .focused(),
            maximumResponseSize: 2048
        ))
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: [tool],
            instructions: """
            You answer questions about the user's AgentTasks queue. Search Spotlight \
            for open tasks — titles, tags (keywords), list names, and notes. Only use \
            retrieved tasks. If nothing matches, say so. Be concise; the answer is spoken.
            """
        )
        let response = try await session.respond(to: trimmed)
        return response.content
    }
}

@available(macOS 27.0, *)
struct AskAgentTasksIntent: AppIntent, LongRunningIntent {
    static let title: LocalizedStringResource = "Ask Agent Tasks"
    static let description = IntentDescription(
        "Answers a question about the open agent queue using on-device search over donated tasks.")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Agent Tasks \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await performBackgroundTask {
            progress.totalUnitCount = 1
            defer { progress.completedUnitCount = 1 }
            return try await AgentQueueAsk.answer(question)
        }
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}
