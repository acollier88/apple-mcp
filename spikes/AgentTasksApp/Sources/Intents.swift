import AppIntents
import Foundation

enum CLI {
    static let defaultBinary = "/Users/andrewcollier/Code/apple-mcp/.build/release/apple-tasks"

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
    }
}
