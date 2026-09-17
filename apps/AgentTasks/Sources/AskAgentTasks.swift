import AppIntents
import CoreSpotlight
import Foundation
import FoundationModels

/// On-device Q&A over the donated task index (IDEAS #31 + iOS/macOS 27
/// `SpotlightSearchTool`), plus the audit/dispatch ledger for completed work.
///
/// Spotlight only has *open* tasks. "When was the last successful heal?" is
/// a ledger question — and Apple's on-device guardrails treat "heal" as
/// medical, so timeline+lane questions are answered from SQLite, not the model.
@available(macOS 27.0, *)
enum AgentQueueAsk {
    static func answer(_ question: String) async throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AgentTasks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Ask a question about the queue."])
        }

        let ledger = LedgerSnapshot.load()
        if let direct = ledger.timelineAnswer(for: trimmed) {
            return direct
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
            You answer questions about AgentTasks, a software agent task queue \
            (Apple Reminders + dispatch). This is never medical. Vocabulary: \
            host-ops-lane = the heal agent (repairs Home Assistant/Hermes/TCC); \
            house-probe-lane = the doctor agent (healthchecks that enqueue host-ops \
            work); cursor/claude/hermes = coding or home agents; auto = unattended \
            dispatch; dispatched/failed = claim chips. \
            Search Spotlight for OPEN tasks (titles, tags, lists, notes). \
            Completed or historical work is only in the Recent activity excerpt \
            in the question — do not invent runs. If nothing matches, say so. \
            Be concise; the answer is spoken.
            """
        )
        let prompt = """
        Software agent-queue question (not medicine, not health records):
        \(Self.demedicalize(trimmed))

        Recent activity, newest first (host-ops-lane = heal agent):
        \(Self.demedicalize(ledger.excerpt()))
        """
        do {
            let response = try await session.respond(to: prompt)
            if Self.looksLikeRefusal(response.content),
               let fallback = ledger.timelineAnswer(for: trimmed, force: true) {
                return fallback
            }
            return response.content
        } catch {
            if let fallback = ledger.timelineAnswer(for: trimmed, force: true) {
                return fallback
            }
            throw error
        }
    }

    /// Rewrite lane names that trip Apple Intelligence medical/timeline guards.
    private static func demedicalize(_ text: String) -> String {
        var out = text
        // Longest first; each pattern applied once.
        let pairs = [
            ("healing", "host-ops-repair"),
            ("healed", "host-ops-repaired"),
            ("heals", "host-ops-lane"),
            ("heal", "host-ops-lane"),
            ("doctor", "house-probe-lane"),
        ]
        for (from, to) in pairs {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: from))\\b"
            out = out.replacingOccurrences(of: pattern, with: to, options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private static func looksLikeRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("medical")
            || lower.contains("health record")
            || lower.contains("i can't process")
            || lower.contains("i cannot process")
            || lower.contains("can't help with that")
    }
}

// MARK: - Ledger grounding (no model)

@available(macOS 27.0, *)
private struct LedgerSnapshot {
    struct LogRow: Decodable {
        let ts: String
        let caller: String
        let command: String
        let detail: String?
        let result: String
    }

    var log: [LogRow]
    var runs: [DispatchLedgerRow]

    static let lanes = [
        "antigravity", "hermes", "cursor", "claude", "doctor", "triage",
        "codex", "gemini", "heal", "agy", "auto",
    ]

    static func load() -> LedgerSnapshot {
        let log: [LogRow]
        if let json = try? CLI.run(["log", "--limit", "80"], timeout: 15),
           let rows = try? JSONDecoder().decode([LogRow].self, from: Data(json.utf8)) {
            log = rows
        } else {
            log = []
        }
        let runs: [DispatchLedgerRow]
        if let json = try? CLI.run(["dispatches", "--limit", "40"], timeout: 15),
           let rows = try? JSONDecoder().decode([DispatchLedgerRow].self, from: Data(json.utf8)) {
            runs = rows
        } else {
            runs = []
        }
        return LedgerSnapshot(log: log, runs: runs)
    }

    func excerpt(limit: Int = 24) -> String {
        let lines = log.prefix(limit).map { row -> String in
            let detail = String((row.detail ?? "").prefix(90))
            return "\(Self.relative(row.ts)) \(row.command) \(row.caller) \(detail)"
        }
        return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
    }

    /// "When was the last successful heal?" — answer from ledger, not Spotlight.
    func timelineAnswer(for question: String, force: Bool = false) -> String? {
        let lower = question.lowercased()
        let temporal = ["when", "last", "latest", "recent", "history", "ago", "timeline", "previously"]
            .contains { Self.containsWord($0, in: lower) }
        guard force || temporal else { return nil }
        guard let lane = Self.lanes.first(where: { Self.containsWord($0, in: lower) }) else {
            return nil
        }

        let wantFailed = ["failed", "failure", "failing", "error"].contains { Self.containsWord($0, in: lower) }
        let wantSuccess = !wantFailed

        if wantSuccess {
            // Prefer the reminder complete (Activity tab) over the dispatch
            // trailer — that's the "successful heal" the ops console shows.
            if let row = log.first(where: { Self.logMatches(row: $0, lane: lane, command: "complete") }) {
                let title = Self.cleanTitle(row.detail ?? "")
                return "Last successful \(lane) completed \(Self.relative(row.ts)): \(title)."
            }
            if let run = runs.first(where: {
                $0.agent.compare(lane, options: .caseInsensitive) == .orderedSame
                    && $0.status == "succeeded"
            }) {
                let when = Self.relative(run.finishedAt ?? run.startedAt)
                let title = Self.cleanTitle(run.summary ?? "")
                if title.isEmpty {
                    return "Last successful \(lane) dispatch finished \(when)."
                }
                return "Last successful \(lane) finished \(when): \(title)."
            }
            if let run = runs.first(where: {
                $0.agent.compare(lane, options: .caseInsensitive) == .orderedSame
            }) {
                let when = Self.relative(run.finishedAt ?? run.startedAt)
                return "No successful \(lane) in the recent ledger. Last \(lane) dispatch \(run.status) \(when)."
            }
            return "No recent \(lane) runs in the audit log or dispatch ledger."
        }

        if let run = runs.first(where: {
            $0.agent.compare(lane, options: .caseInsensitive) == .orderedSame
                && ($0.status == "failed" || $0.status == "timeout")
        }) {
            let when = Self.relative(run.finishedAt ?? run.startedAt)
            return "Last failed \(lane) \(run.status) \(when)."
        }
        return "No recent failed \(lane) dispatches in the ledger."
    }

    private static func logMatches(row: LogRow, lane: String, command: String) -> Bool {
        guard row.command == command else { return false }
        let hay = "\(row.detail ?? "") \(row.caller)".lowercased()
        return hay.contains("[\(lane)]") || hay.contains("agent:\(lane)")
            || Self.containsWord(lane, in: hay)
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func cleanTitle(_ raw: String) -> String {
        var rest = raw.trimmingCharacters(in: .whitespaces)
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return rest
    }

    private static func relative(_ iso: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: iso) ?? basic.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

@available(macOS 27.0, *)
struct AskAgentTasksIntent: AppIntent, LongRunningIntent {
    static let title: LocalizedStringResource = "Ask Agent Tasks"
    static let description = IntentDescription(
        "Answers a question about the agent queue: open tasks via Spotlight, completed runs via the audit log.")

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
