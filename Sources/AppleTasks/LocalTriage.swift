import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// IDEAS #27: on-device triage classifier. `apple-tasks triage --agent local`
// (or "agent": "local" in the dispatcher's triage block) classifies with
// Apple's SystemLanguageModel instead of spawning an external agent process:
// zero API cost, offline, and @Generable structured output means no
// JSON-parsing slop. Same contract as every classifier: it only judges;
// Triage applies and audits every mutation.

enum LocalClassifier {
    /// Reserved --agent value that selects the on-device model.
    static let agentTag = "local"

    /// Doctor line: on-device model availability for THIS host process.
    static func status() -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "requires macOS 26+" }
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        @unknown default: return "unknown availability"
        }
        #else
        return "not compiled in (SDK lacks FoundationModels)"
        #endif
    }

    /// Classify inbox items one at a time (small on-device model: per-item
    /// prompts are more reliable than one big batch, and ids can't be
    /// hallucinated — we map results positionally).
    static func classify(items: [[String: String]], agents: [String], workdirs: [String],
                         planLists: [String]) async throws -> [Triage.Classification] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw AppleTasksError.saveFailed("local triage needs macOS 26+ (FoundationModels)")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw AppleTasksError.saveFailed(
                "on-device model \(status()) — check Apple Intelligence in System Settings")
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
        You are an inbox triage classifier for a task queue. Classify each reminder as \
        "agent" (actionable software/repo work an AI coding agent could do) or "personal" \
        (errands, appointments, finances — anything not software work).
        For agent work choose: an agent from [\(agents.joined(separator: ", "))]; a repo \
        from [\(workdirs.joined(separator: ", "))] only if one clearly applies; and a plan \
        list from [\(planLists.joined(separator: ", "))] — agent work should normally move \
        to the most relevant plan list, so pick one unless none fits at all.
        """)

        var out: [Triage.Classification] = []
        for item in items {
            var prompt = "Reminder: \(item["title"] ?? "")"
            if let notes = item["notes"], !notes.isEmpty { prompt += "\nNotes: \(notes)" }
            let decision = try await session.respond(to: prompt, generating: Decision.self).content

            // The static schema can't express dynamic enums, so validate the
            // model's picks against the known sets and drop anything else.
            var tags: [String] = []
            if let a = decision.agent,
               let match = agents.first(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                tags.append(match)
            }
            if let r = decision.repo,
               let match = workdirs.first(where: { $0.caseInsensitiveCompare(r) == .orderedSame }) {
                tags.append(match)
            }
            out.append(.init(id: item["id"] ?? "", kind: decision.kind,
                             tags: tags, list: decision.list))
        }
        return out
        #else
        throw AppleTasksError.saveFailed("local triage not compiled in (SDK lacks FoundationModels)")
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct Decision {
    @Guide(description: "\"agent\" for software/repo work an AI coding agent could do; \"personal\" for everything else",
           .anyOf(["agent", "personal"]))
    var kind: String
    @Guide(description: "For agent work: which agent to route to, from the allowed list")
    var agent: String?
    @Guide(description: "For agent work: the repo tag, only if one clearly applies")
    var repo: String?
    @Guide(description: "For agent work: the target plan list, only if one fits")
    var list: String?
}
#endif
