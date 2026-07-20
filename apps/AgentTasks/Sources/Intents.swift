import AppIntents
import Foundation

enum CLI {
    /// Resolve the monorepo CLI build (apps/AgentTasks → ../../cli/.build/release).
    /// Override with APPLE_TASKS_BIN when the app is installed outside the checkout.
    static var defaultBinary: String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // AgentTasks
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("cli/.build/release/apple-tasks").path
    }

    static func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["APPLE_TASKS_BIN"] ?? defaultBinary)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "AgentTasks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: detail.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

struct QueryAgentTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Agent Tasks"
    static let description = IntentDescription("Lists open agent tasks from Apple Reminders, optionally filtered by tag or list.")

    @Parameter(title: "Tag")
    var tag: String?

    @Parameter(title: "List")
    var list: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Check open agent tasks") {
            \.$tag
            \.$list
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        var args = ["list", "--status", "open"]
        if let tag, !tag.isEmpty { args += ["--tag", tag] }
        if let list, !list.isEmpty { args += ["--list", list] }
        let json = try CLI.run(args)

        struct Task: Decodable {
            let title: String
            let list: String
            let tags: [String]
        }
        let tasks = (try? JSONDecoder().decode([Task].self, from: Data(json.utf8))) ?? []

        let summary: String
        if tasks.isEmpty {
            summary = "No open agent tasks."
        } else {
            let lines = tasks.prefix(6).map { task in
                task.tags.isEmpty ? "\(task.title) (\(task.list))"
                    : "\(task.title) (\(task.list), \(task.tags.joined(separator: ", ")))"
            }
            summary = "\(tasks.count) open task\(tasks.count == 1 ? "" : "s"): " + lines.joined(separator: "; ")
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct CreateAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Agent Task"
    static let description = IntentDescription("Creates a tagged task in the agent queue (Apple Reminders).")

    @Parameter(title: "Title")
    var taskTitle: String

    @Parameter(title: "List", default: "Code Tasks")
    var list: String

    @Parameter(title: "Tags (comma-separated)", default: "claude")
    var tags: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add agent task \(\.$taskTitle)") {
            \.$list
            \.$tags
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var args = ["add", "--list", list]
        for tag in tags.split(separator: ",") {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { args += ["--tag", trimmed] }
        }
        args.append(taskTitle)
        _ = try CLI.run(args)
        return .result(dialog: IntentDialog(stringLiteral: "Added \"\(taskTitle)\" to \(list)."))
    }
}

struct TriageInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Triage Agent Inbox"
    static let description = IntentDescription("Classifies and routes untagged reminders in the inbox: agent work gets tagged and filed, personal items get a [personal] tag.")

    @Parameter(title: "Inbox List", default: "Reminders")
    var inbox: String

    static var parameterSummary: some ParameterSummary {
        Summary("Triage \(\.$inbox) inbox")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let json = try CLI.run(["triage", "--inbox", inbox, "--apply"])
        // Parse the small result to speak a count; fall back to raw on any change.
        var spoken = "Triage complete."
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let actions = obj["actions"] as? [[String: Any]] {
            let agents = actions.filter { ($0["kind"] as? String) == "agent" }.count
            let personal = actions.filter { ($0["kind"] as? String) == "personal" }.count
            if actions.isEmpty {
                spoken = "Nothing to triage — the inbox has no untagged items."
            } else {
                spoken = "Triaged \(actions.count) item\(actions.count == 1 ? "" : "s"): \(agents) routed to agents, \(personal) marked personal."
            }
        }
        return .result(value: json, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct AgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Agent Status Report"
    static let description = IntentDescription("Speaks what the agents did recently: dispatch outcomes, agent actions, tasks due today, and today's calendar load.")

    @Parameter(title: "Since (e.g. 2026-07-07 or ISO8601)", default: nil)
    var since: String?

    static var parameterSummary: some ParameterSummary {
        Summary("What did my agents do?") {
            \.$since
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        var args = ["digest"]
        if let since, !since.isEmpty { args += ["--since", since] }
        let json = try CLI.run(args)

        struct Digest: Decodable {
            struct Line: Decodable { let agent: String; let status: String }
            struct Item: Decodable { let title: String }
            let dispatches: [Line]
            let auditActions: Int
            let dueToday: [Item]
            let events: [Item]
        }
        guard let d = try? JSONDecoder().decode(Digest.self, from: Data(json.utf8)) else {
            return .result(value: json, dialog: "Couldn't read the digest.")
        }

        let ok = d.dispatches.filter { $0.status == "succeeded" }.count
        let failed = d.dispatches.count - ok
        var parts: [String] = []
        if d.dispatches.isEmpty {
            parts.append("No agent runs")
        } else {
            parts.append("\(d.dispatches.count) agent run\(d.dispatches.count == 1 ? "" : "s"): \(ok) succeeded"
                + (failed > 0 ? ", \(failed) failed" : ""))
        }
        parts.append("\(d.auditActions) action\(d.auditActions == 1 ? "" : "s") in the audit log")
        parts.append(d.dueToday.isEmpty ? "nothing due today"
            : "\(d.dueToday.count) task\(d.dueToday.count == 1 ? "" : "s") due today: "
              + d.dueToday.prefix(3).map(\.title).joined(separator: ", "))
        parts.append(d.events.isEmpty ? "calendar is clear"
            : "\(d.events.count) event\(d.events.count == 1 ? "" : "s") on the calendar")
        let spoken = parts.joined(separator: ". ") + "."
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct AgentTasksShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QueryAgentTasksIntent(),
            phrases: [
                "Check agent tasks in \(.applicationName)",
                "What's in my \(.applicationName) queue",
            ],
            shortTitle: "Check Agent Tasks",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CreateAgentTaskIntent(),
            phrases: [
                "Add an agent task in \(.applicationName)",
            ],
            shortTitle: "Add Agent Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: AgentStatusIntent(),
            phrases: [
                "What did my agents do in \(.applicationName)",
                "Agent status in \(.applicationName)",
            ],
            shortTitle: "Agent Status",
            systemImageName: "waveform.and.person.filled"
        )
        AppShortcut(
            intent: TriageInboxIntent(),
            phrases: [
                "Triage my \(.applicationName) inbox",
                "Triage my inbox in \(.applicationName)",
            ],
            shortTitle: "Triage Inbox",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
