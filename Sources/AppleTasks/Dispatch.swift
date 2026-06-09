import ArgumentParser
import EventKit
import Foundation

// MARK: - log / dispatches (read the machine-side memory)

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the audit log: what was done, when, by which caller."
    )

    @Option(help: "Only entries at/after this ISO8601 timestamp or yyyy-MM-dd.")
    var since: String?

    @Option(name: .customLong("task"), help: "Only entries for this task id.")
    var taskId: String?

    @Option(help: "Filter by caller substring (mcp, app, dispatcher, zsh...).")
    var caller: String?

    @Option(help: "Max rows (default 50, newest first).")
    var limit: Int = 50

    func run() async throws {
        emit(AuditDB.shared.auditRows(since: since, taskId: taskId, caller: caller, limit: limit))
    }
}

struct Dispatches: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the dispatch ledger (agent runs and their outcomes)."
    )

    @Option(help: "Filter: running | succeeded | failed.")
    var status: String?

    @Option(help: "Max rows (default 50, newest first).")
    var limit: Int = 50

    func run() async throws {
        emit(AuditDB.shared.dispatchRows(status: status, limit: limit))
    }
}

// MARK: - dispatch

struct AgentsConfig: Codable {
    struct Agent: Codable {
        /// Command argv; "{prompt}" is replaced with the rendered prompt.
        let command: [String]
        let promptTemplate: String?
    }

    var agents: [String: Agent]
    /// Repo/project tag -> working directory.
    var workdirs: [String: String]?
    /// When true (default), only tasks also tagged [auto] are dispatched.
    var requireAutoTag: Bool?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/agents.json")
    }

    static func load() throws -> AgentsConfig {
        guard let data = try? Data(contentsOf: url) else {
            throw AppleTasksError.saveFailed("no agents config at \(url.path); create it to enable dispatch")
        }
        return try JSONDecoder().decode(AgentsConfig.self, from: data)
    }

    static let defaultPromptTemplate = """
    You have been dispatched a task from AgentTasks (Apple Reminders).
    Task id: {id}
    List: {list}
    Title: {title}
    Notes: {notes}
    Do the work described by the task. When finished, mark it done by running:
    apple-tasks complete {id}
    and remove the dispatched marker: apple-tasks update {id} --remove-tag dispatched
    """
}

struct Dispatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Find open agent-tagged tasks and launch the configured agent for each. \
        Config: ~/.config/apple-tasks/agents.json. Dedupe via the dispatch \
        ledger + a [dispatched] tag. v1 runs tasks sequentially.
        """
    )

    @Flag(name: .customLong("dry-run"), help: "Show what would be dispatched without running anything.")
    var dryRun = false

    @Option(name: .customLong("agent"), help: "Only dispatch tasks for this agent tag.")
    var onlyAgent: String?

    @Option(name: .customLong("list"), help: "Only scan this Reminders list.")
    var listName: String?

    struct DispatchReport: Codable {
        let taskId: String
        let title: String
        let agent: String
        let cwd: String?
        let action: String
        let exitCode: Int?
    }

    func run() async throws {
        let config = try AgentsConfig.load()
        let requireAuto = config.requireAutoTag ?? true

        let store = Store()
        try await store.requestAccess()
        let calendars = try listName.map { [try store.calendar(named: $0)] }
        let reminders = await store.reminders(in: calendars).filter { !$0.isCompleted }

        var reports: [DispatchReport] = []
        for reminder in reminders {
            let parsed = Tags.parse(reminder.title ?? "")
            let lowerTags = Set(parsed.tags.map { $0.lowercased() })

            guard let agentTag = parsed.tags.first(where: { config.agents[$0.lowercased()] != nil })?.lowercased(),
                  let agent = config.agents[agentTag] else { continue }
            if let onlyAgent, agentTag != onlyAgent.lowercased() { continue }
            if requireAuto && !lowerTags.contains("auto") { continue }
            if lowerTags.contains("dispatched") || lowerTags.contains("failed") { continue }

            let taskId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
            if AuditDB.shared.hasActiveDispatch(taskId: taskId) { continue }

            let cwd = parsed.tags.lazy
                .compactMap { config.workdirs?[$0.lowercased()] }
                .first
                .map { NSString(string: $0).expandingTildeInPath }

            let prompt = (agent.promptTemplate ?? AgentsConfig.defaultPromptTemplate)
                .replacingOccurrences(of: "{id}", with: taskId)
                .replacingOccurrences(of: "{list}", with: reminder.calendar?.title ?? "")
                .replacingOccurrences(of: "{title}", with: parsed.title)
                .replacingOccurrences(of: "{notes}", with: reminder.notes ?? "(none)")
            let argv = agent.command.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }

            if dryRun {
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: "would dispatch", exitCode: nil))
                continue
            }

            // Mark dispatched (visible everywhere via tag + native mirror).
            var tags = parsed.tags
            tags.append("dispatched")
            reminder.title = Tags.compose(tags: tags, title: parsed.title)
            try store.save(reminder)
            _ = NativeTags.mirror(tags: ["dispatched"], externalId: reminder.calendarItemExternalIdentifier)

            let ledgerId = AuditDB.shared.startDispatch(
                taskId: taskId, agent: agentTag, command: argv.joined(separator: " "), cwd: cwd)
            AuditDB.shared.record(command: "dispatch", taskId: taskId,
                                  list: reminder.calendar?.title, detail: "\(agentTag): \(parsed.title)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["APPLE_TASKS_CALLER"] = "agent:\(agentTag)"
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
                let code = process.terminationStatus
                AuditDB.shared.finishDispatch(id: ledgerId, status: code == 0 ? "succeeded" : "failed", exitCode: code)
                if code != 0 {
                    // Re-fetch: the agent may have edited the task meanwhile.
                    if let current = try? await store.reminder(id: taskId) {
                        var (currentTags, currentTitle) = Tags.parse(current.title ?? "")
                        currentTags.removeAll { $0.lowercased() == "dispatched" }
                        if !currentTags.contains(where: { $0.lowercased() == "failed" }) {
                            currentTags.append("failed")
                        }
                        current.title = Tags.compose(tags: currentTags, title: currentTitle)
                        try? store.save(current)
                    }
                }
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: code == 0 ? "succeeded" : "failed",
                                              exitCode: Int(code)))
            } catch {
                AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: -1)
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: "spawn failed: \(error.localizedDescription)",
                                              exitCode: nil))
            }
        }
        emit(reports)
    }
}
