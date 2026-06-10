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
        /// Run in a fresh git worktree of the workdir (output = a branch, not
        /// edits to the main checkout). Requires the workdir to be a git repo.
        let worktree: Bool?
        /// Kill the agent and mark the run 'timeout' after this many minutes.
        let timeoutMinutes: Int?
    }

    var agents: [String: Agent]
    /// Repo/project tag -> working directory.
    var workdirs: [String: String]?
    /// When true (default), only tasks also tagged [auto] are dispatched.
    var requireAutoTag: Bool?
    /// Re-dispatch [failed] tasks up to this many times (default 0 = never).
    var maxRetries: Int?
    /// Wait this long after the Nth failure before retry N+1 (scales linearly).
    var retryBackoffMinutes: Int?

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

    @Option(name: .customLong("reap-hours"),
            help: "Ledger rows 'running' longer than this are reaped as timed out.")
    var reapHours: Int = 4

    @Flag(name: .customLong("reap-only"), help: "Only reap stale ledger rows, dispatch nothing.")
    var reapOnly = false

    struct DispatchReport: Codable {
        let taskId: String
        let title: String
        let agent: String
        let cwd: String?
        let action: String
        let exitCode: Int?
        let runLog: String?
        let worktree: String?
    }

    func run() async throws {
        let config = try AgentsConfig.load()
        let requireAuto = config.requireAutoTag ?? true

        let store = Store()
        try await store.requestAccess()

        var reports: [DispatchReport] = []

        // Reap first: rows orphaned in 'running' (dispatcher killed mid-run)
        // become 'timeout' and the task's [dispatched] tag becomes [failed],
        // so retry policy can pick them up.
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-TimeInterval(reapHours) * 3600))
        for stale in AuditDB.shared.reapStale(before: cutoff) {
            await markFailed(store: store, taskId: stale.taskId)
            AuditDB.shared.record(command: "dispatch-reap", taskId: stale.taskId,
                                  detail: "ledger #\(stale.id) running since \(stale.startedAt)")
            reports.append(DispatchReport(taskId: stale.taskId, title: "(ledger #\(stale.id))",
                                          agent: stale.agent, cwd: stale.cwd,
                                          action: "reaped: running > \(reapHours)h, marked timeout",
                                          exitCode: nil, runLog: stale.runLogPath, worktree: stale.worktree))
        }
        if reapOnly {
            emit(reports)
            return
        }

        let calendars = try listName.map { [try store.calendar(named: $0)] }
        let reminders = await store.reminders(in: calendars).filter { !$0.isCompleted }

        for reminder in reminders {
            let parsed = Tags.parse(reminder.title ?? "")
            let lowerTags = Set(parsed.tags.map { $0.lowercased() })
            let taskId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier

            guard let agentTag = parsed.tags.first(where: { config.agents[$0.lowercased()] != nil })?.lowercased(),
                  let agent = config.agents[agentTag] else { continue }
            if let onlyAgent, agentTag != onlyAgent.lowercased() { continue }
            if requireAuto && !lowerTags.contains("auto") { continue }
            if lowerTags.contains("dispatched") { continue }

            var retryAttempt: Int?
            if lowerTags.contains("failed") {
                let maxRetries = config.maxRetries ?? 0
                guard maxRetries > 0 else { continue }
                let (attempts, lastFailure) = AuditDB.shared.failedAttempts(taskId: taskId)
                guard attempts <= maxRetries else { continue }
                let backoff = TimeInterval((config.retryBackoffMinutes ?? 30) * 60 * max(attempts, 1))
                if let lastFailure,
                   let lastDate = ISO8601DateFormatter().date(from: lastFailure),
                   Date().timeIntervalSince(lastDate) < backoff { continue }
                retryAttempt = attempts + 1
            }

            if AuditDB.shared.hasActiveDispatch(taskId: taskId) { continue }

            let cwd = parsed.tags.lazy
                .compactMap { config.workdirs?[$0.lowercased()] }
                .first
                .map { NSString(string: $0).expandingTildeInPath }

            var prompt = (agent.promptTemplate ?? AgentsConfig.defaultPromptTemplate)
                .replacingOccurrences(of: "{id}", with: taskId)
                .replacingOccurrences(of: "{list}", with: reminder.calendar?.title ?? "")
                .replacingOccurrences(of: "{title}", with: parsed.title)
                .replacingOccurrences(of: "{notes}", with: reminder.notes ?? "(none)")
            if agent.worktree == true {
                prompt += "\nYou are in a dedicated git worktree on your own branch. " +
                    "Commit your work to the current branch; do not switch branches."
            }
            let argv = agent.command.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }

            if dryRun {
                let action = retryAttempt.map { "would retry (attempt \($0))" } ?? "would dispatch"
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: action, exitCode: nil,
                                              runLog: nil, worktree: nil))
                continue
            }

            // Mark dispatched (visible everywhere via tag + native mirror);
            // a retry sheds its [failed] tag here.
            var tags = parsed.tags.filter { $0.lowercased() != "failed" }
            tags.append("dispatched")
            reminder.title = Tags.compose(tags: tags, title: parsed.title)
            try store.save(reminder)
            _ = NativeTags.mirror(tags: ["dispatched"], externalId: reminder.calendarItemExternalIdentifier)

            let ledgerId = AuditDB.shared.startDispatch(
                taskId: taskId, agent: agentTag, command: argv.joined(separator: " "), cwd: cwd)
            AuditDB.shared.record(command: retryAttempt == nil ? "dispatch" : "dispatch-retry",
                                  taskId: taskId, list: reminder.calendar?.title,
                                  detail: "\(agentTag): \(parsed.title)"
                                      + (retryAttempt.map { " (attempt \($0))" } ?? ""))

            // Worktree isolation: agent output is a branch, never edits to the
            // main checkout. Refuse to run unisolated if creation fails.
            var runCwd = cwd
            var worktreePath: String?
            if agent.worktree == true {
                guard let repo = cwd else {
                    AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: -1)
                    await markFailed(store: store, taskId: taskId)
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                                  cwd: nil, action: "failed: worktree requires a workdir tag",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                    continue
                }
                let wt = AgentsConfig.url.deletingLastPathComponent()
                    .appendingPathComponent("worktrees/\(ledgerId)").path
                let branch = "agent/\(agentTag)-\(ledgerId)"
                let gitCode = Self.runGit(["worktree", "add", "-b", branch, wt], repo: repo)
                guard gitCode == 0 else {
                    AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: gitCode)
                    await markFailed(store: store, taskId: taskId)
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                                  cwd: repo, action: "failed: git worktree add exited \(gitCode)",
                                                  exitCode: Int(gitCode), runLog: nil, worktree: nil))
                    continue
                }
                runCwd = wt
                worktreePath = wt
            }

            // Run log: everything the agent prints, kept per ledger row.
            let runsDir = AgentsConfig.url.deletingLastPathComponent().appendingPathComponent("runs")
            try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
            let logURL = runsDir.appendingPathComponent("\(ledgerId).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = FileHandle(forWritingAtPath: logURL.path)
            logHandle?.write(Data("""
            # dispatch #\(ledgerId) \(ISO8601DateFormatter().string(from: Date()))
            # task \(taskId): \(parsed.title)
            # \(argv.joined(separator: " "))\n\n
            """.utf8))
            AuditDB.shared.setDispatchPaths(id: ledgerId, runLogPath: logURL.path, worktree: worktreePath)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            if let runCwd { process.currentDirectoryURL = URL(fileURLWithPath: runCwd) }
            var env = ProcessInfo.processInfo.environment
            env["APPLE_TASKS_CALLER"] = "agent:\(agentTag)"
            process.environment = env
            if let logHandle {
                process.standardOutput = logHandle
                process.standardError = logHandle
            }

            do {
                try process.run()
                var timedOut = false
                if let minutes = agent.timeoutMinutes {
                    let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
                    while process.isRunning && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                        for _ in 0..<5 where process.isRunning {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                process.waitUntilExit()
                try? logHandle?.close()
                let code = process.terminationStatus
                let status = timedOut ? "timeout" : (code == 0 ? "succeeded" : "failed")
                AuditDB.shared.finishDispatch(id: ledgerId, status: status, exitCode: code)
                if status != "succeeded" {
                    await markFailed(store: store, taskId: taskId)
                }
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: runCwd, action: status, exitCode: Int(code),
                                              runLog: logURL.path, worktree: worktreePath))
            } catch {
                try? logHandle?.close()
                AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: -1)
                await markFailed(store: store, taskId: taskId)
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: runCwd, action: "spawn failed: \(error.localizedDescription)",
                                              exitCode: nil, runLog: logURL.path, worktree: worktreePath))
            }
        }
        emit(reports)
    }

    /// Swap [dispatched] for [failed] on the task, re-fetching first because
    /// the agent may have edited it meanwhile.
    private func markFailed(store: Store, taskId: String) async {
        guard let current = try? await store.reminder(id: taskId) else { return }
        var (tags, title) = Tags.parse(current.title ?? "")
        tags.removeAll { $0.lowercased() == "dispatched" }
        if !tags.contains(where: { $0.lowercased() == "failed" }) {
            tags.append("failed")
        }
        current.title = Tags.compose(tags: tags, title: title)
        try? store.save(current)
        _ = NativeTags.mirror(tags: ["failed"], externalId: current.calendarItemExternalIdentifier)
    }

    private static func runGit(_ args: [String], repo: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
