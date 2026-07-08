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
        /// Max simultaneous runs for THIS agent (default: no per-agent cap).
        let maxConcurrent: Int?
        /// Context gates (IDEAS #22): all must pass or the task stays queued
        /// (no claim, no [failed]) and is retried next pass.
        let conditions: Conditions?
    }

    struct Conditions: Codable {
        /// Named place from `places` this Mac must be within.
        let location: String?
        /// Required power source: "ac" | "battery".
        let power: String?
        /// Skip dispatch while the 1-minute load average exceeds this.
        let maxLoad: Double?
    }

    struct Place: Codable {
        let lat: Double
        let lon: Double
        /// Geofence radius in meters (default 150).
        let radiusM: Double?
    }

    struct TriageConfig: Codable {
        /// Agent tag in `agents` used as the classifier (default "triage").
        let agent: String?
        /// Reminders list to triage (default "Reminders").
        let inbox: String?
    }

    var agents: [String: Agent]
    /// Named places for `conditions.location` gates.
    var places: [String: Place]?
    /// When present, run a one-shot inbox triage (see Triage.swift) at the
    /// start of every dispatch cycle, before scanning for dispatchable tasks.
    var triage: TriageConfig?
    /// Max simultaneous agent runs overall (default 1 = v1 sequential behavior).
    var maxConcurrent: Int?
    /// Repo/project tag -> working directory.
    var workdirs: [String: String]?
    /// When true (default), only tasks also tagged [auto] are dispatched.
    var requireAutoTag: Bool?
    /// Re-dispatch [failed] tasks up to this many times (default 0 = never).
    var maxRetries: Int?
    /// Wait this long after the Nth failure before retry N+1 (scales linearly).
    var retryBackoffMinutes: Int?
    /// Keep failed/timeout worktrees this many days before GC (default 7).
    var keepFailedWorktreeDays: Int?
    /// macOS notification on run finish: "failure" (default) | "all" | "none".
    var notifyOn: String?

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
    Do the work described by the task. When finished, record a 1-3 sentence
    outcome summary: apple-tasks update {id} --append-notes "<what you did>"
    If your work produced a PR, commit, or file, link it:
    apple-tasks update {id} --url "<link>"
    then mark it done by running:
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

    @Flag(name: .customLong("no-gc"), help: "Skip worktree garbage collection this run.")
    var noGC = false

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
        // Worktree GC: reclaim worktrees of finished runs. Merged succeeded
        // branches (and their worktrees) go immediately; failed/timeout
        // worktrees are kept keepFailedWorktreeDays for debugging; unmerged
        // succeeded branches are deliverables and are only surfaced.
        if !noGC {
            let keepDays = config.keepFailedWorktreeDays ?? 7
            let keepCutoff = Date().addingTimeInterval(-TimeInterval(keepDays) * 86400)
            let iso = ISO8601DateFormatter()
            for row in AuditDB.shared.worktreeRows() {
                guard let wt = row.worktree, let repo = row.cwd, !repo.isEmpty else { continue }
                guard FileManager.default.fileExists(atPath: wt) else {
                    AuditDB.shared.clearWorktree(id: Int64(row.id))
                    continue
                }
                let branch = "agent/\(row.agent)-\(row.id)"
                var action: String?
                switch row.status {
                case "succeeded":
                    if Self.runGit(["merge-base", "--is-ancestor", branch, "HEAD"], repo: repo) == 0 {
                        _ = Self.runGit(["worktree", "remove", "--force", wt], repo: repo)
                        _ = Self.runGit(["branch", "-d", branch], repo: repo)
                        AuditDB.shared.clearWorktree(id: Int64(row.id))
                        action = "gc: branch \(branch) merged, worktree removed"
                    } else {
                        action = "gc: kept, unmerged branch \(branch) pending"
                    }
                case "failed", "timeout":
                    guard let finished = row.finishedAt,
                          let date = iso.date(from: finished), date < keepCutoff else { continue }
                    let empty = Self.gitOutput(["rev-list", "--count", branch, "--not", "HEAD"],
                                               repo: repo) == "0"
                    _ = Self.runGit(["worktree", "remove", "--force", wt], repo: repo)
                    if empty { _ = Self.runGit(["branch", "-D", branch], repo: repo) }
                    AuditDB.shared.clearWorktree(id: Int64(row.id))
                    action = "gc: removed \(row.status) worktree (>\(keepDays)d), "
                        + (empty ? "empty branch deleted" : "branch \(branch) kept")
                default:
                    break
                }
                if let action {
                    reports.append(DispatchReport(taskId: row.taskId, title: "(ledger #\(row.id))",
                                                  agent: row.agent, cwd: repo, action: action,
                                                  exitCode: nil, runLog: row.runLogPath, worktree: wt))
                }
            }
        }

        if reapOnly {
            emit(reports)
            return
        }

        // Auto-triage (salvaged from PR #3, reworked): when agents.json has a
        // "triage" block, classify and route untagged inbox items before the
        // scan, so voice captures get tagged — and, if routed with [auto],
        // dispatched — in the same cycle. Same rule as everywhere else: the
        // classifier agent only judges; this CLI applies and audits every
        // mutation (see Triage.swift). Triage failure never blocks dispatch.
        if let t = config.triage {
            let inbox = t.inbox ?? "Reminders"
            let triageAgent = t.agent ?? "triage"
            if dryRun {
                reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                              agent: triageAgent, cwd: nil,
                                              action: "would triage untagged inbox items before dispatch",
                                              exitCode: nil, runLog: nil, worktree: nil))
            } else {
                do {
                    let result = try await Triage.triage(store: store, inbox: inbox,
                                                         agentTag: triageAgent, apply: true)
                    if result.untaggedCount > 0 {
                        let agentCount = result.actions.filter { $0.kind == "agent" }.count
                        let personal = result.actions.filter { $0.kind == "personal" }.count
                        reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                                      agent: triageAgent, cwd: nil,
                                                      action: "triaged \(result.actions.count): \(agentCount) agent, \(personal) personal",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                } catch {
                    reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                                  agent: triageAgent, cwd: nil,
                                                  action: "triage failed: \(error.localizedDescription)",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
            }
        }

        let calendars = try listName.map { [try store.calendar(named: $0)] }
        let reminders = await store.reminders(in: calendars).filter { !$0.isCompleted }

        // Phase A (serial, EventKit + ledger): scan, claim, tag, prepare.
        // Emits plain-value RunSpecs; no EKReminder crosses into Phase B.
        var specs: [RunSpec] = []
        var specsPerAgent: [String: Int] = [:]
        let gates = GateContext() // probes cached across candidates this pass

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

            // Per-agent cap: ledger 'running' rows + specs already queued this
            // pass. A full agent is skipped; the next dispatch picks it up.
            if let cap = agent.maxConcurrent,
               AuditDB.shared.activeDispatchCount(agent: agentTag)
                   + specsPerAgent[agentTag, default: 0] >= cap { continue }

            // Context gates (IDEAS #22): a failed gate leaves the task
            // queued untouched — reconsidered next pass, never [failed].
            if let conditions = agent.conditions,
               let reason = await gates.gateReason(conditions, config: config) {
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: nil, action: "gated: \(reason) — stays queued",
                                              exitCode: nil, runLog: nil, worktree: nil))
                continue
            }

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
            if lowerTags.contains("pr") {
                prompt += "\nThis task requires a Pull Request. When finished, push your branch to origin with 'git push -u origin HEAD' and open a PR with 'gh pr create' (title + a body describing the change and how you verified). Run these commands to associate it: apple-tasks update \(taskId) --url \"<PR url>\""
            }
            let argv = agent.command.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }

            if dryRun {
                let action = retryAttempt.map { "would retry (attempt \($0))" } ?? "would dispatch"
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: action, exitCode: nil,
                                              runLog: nil, worktree: nil))
                continue
            }

            // Atomic claim first: the ledger row is the lock (single-statement
            // insert-if-absent), so two dispatchers can't both take the task.
            guard let ledgerId = AuditDB.shared.claimDispatch(
                taskId: taskId, agent: agentTag, command: argv.joined(separator: " "), cwd: cwd) else {
                continue // another dispatcher claimed it between our scan and now
            }

            // Mark dispatched (visible everywhere via tag + native mirror);
            // a retry sheds its [failed] tag here. Written after the claim so
            // a crash between the two can't strand the tag with no ledger row.
            var tags = parsed.tags.filter { $0.lowercased() != "failed" }
            tags.append("dispatched")
            reminder.title = Tags.compose(tags: tags, title: parsed.title)
            do {
                try store.save(reminder)
            } catch {
                AuditDB.shared.finishDispatch(id: ledgerId, status: "aborted", exitCode: -1)
                throw error
            }
            _ = NativeTags.mirror(tags: ["dispatched"], externalId: reminder.calendarItemExternalIdentifier)
            AuditDB.shared.record(command: retryAttempt == nil ? "dispatch" : "dispatch-retry",
                                  taskId: taskId, list: reminder.calendar?.title,
                                  detail: "\(agentTag): \(parsed.title)"
                                      + (retryAttempt.map { " (attempt \($0))" } ?? ""))

            // Worktree isolation: agent output is a branch, never edits to the
            // main checkout. Refuse to run unisolated if creation fails.
            var runCwd = cwd
            var worktreePath: String?
            var branchName: String?
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
                branchName = branch
            }

            // Run log: everything the agent prints, kept per ledger row.
            let runsDir = AgentsConfig.url.deletingLastPathComponent().appendingPathComponent("runs")
            try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
            let logURL = runsDir.appendingPathComponent("\(ledgerId).log")
            AuditDB.shared.setDispatchPaths(id: ledgerId, runLogPath: logURL.path, worktree: worktreePath)

            specs.append(RunSpec(ledgerId: ledgerId, taskId: taskId, title: parsed.title,
                                 agentTag: agentTag, argv: argv, repo: cwd, runCwd: runCwd,
                                 worktree: worktreePath, branch: branchName,
                                 timeoutMinutes: agent.timeoutMinutes, logPath: logURL.path))
            specsPerAgent[agentTag, default: 0] += 1
        }

        // Phase B (concurrent, EventKit-free): run the agents, capped. The
        // collection loop below runs serially on this task, so recording and
        // write-backs (Phase C) happen per-outcome, as each agent finishes.
        let cap = max(config.maxConcurrent ?? 1, 1)
        await withTaskGroup(of: RunOutcome.self) { group in
            var pending = specs.makeIterator()
            var inFlight = 0
            while inFlight < cap, let spec = pending.next() {
                group.addTask { await Self.execute(spec) }
                inFlight += 1
            }
            while let outcome = await group.next() {
                if let spec = pending.next() {
                    group.addTask { await Self.execute(spec) }
                }
                let spec = outcome.spec
                let trailerText = trailer(ledgerId: spec.ledgerId, status: outcome.status,
                                          exitCode: outcome.exitCode, branch: spec.branch,
                                          repo: spec.repo, logPath: spec.logPath)
                AuditDB.shared.finishDispatch(id: spec.ledgerId,
                                              status: outcome.status == "succeeded" ? "succeeded" : outcome.status == "timeout" ? "timeout" : "failed",
                                              exitCode: outcome.exitCode ?? -1,
                                              summary: trailerText.components(separatedBy: "\n").first)
                if outcome.status != "succeeded" {
                    await markFailed(store: store, taskId: spec.taskId)
                }
                await appendNotesTrailer(store: store, taskId: spec.taskId, trailer: trailerText)
                let notifyOn = config.notifyOn ?? "failure"
                let summaryLine = trailerText.components(separatedBy: "\n").first ?? outcome.status
                if notifyOn == "all" || (notifyOn == "failure" && outcome.status != "succeeded") {
                    Notifier.banner(title: spec.title, body: summaryLine)
                }
                // Failures always reach the phone when ntfy is configured —
                // the banner is useless if you're not at the Mac.
                if outcome.status != "succeeded" {
                    await Notifier.push(title: "agent \(outcome.status): \(spec.title)", body: summaryLine)
                }
                let action = outcome.spawnError.map { "spawn failed: \($0)" } ?? outcome.status
                reports.append(DispatchReport(taskId: spec.taskId, title: spec.title, agent: spec.agentTag,
                                              cwd: spec.runCwd, action: action,
                                              exitCode: outcome.exitCode.map(Int.init),
                                              runLog: spec.logPath, worktree: spec.worktree))
            }
        }
        emit(reports)
    }

    /// Everything Phase B needs to run one agent; value-typed so it can cross
    /// into the task group (EKReminder must not).
    struct RunSpec: Sendable {
        let ledgerId: Int64
        let taskId: String
        let title: String
        let agentTag: String
        let argv: [String]
        /// The workdir/repo (for trailer git queries), not the process cwd.
        let repo: String?
        let runCwd: String?
        let worktree: String?
        let branch: String?
        let timeoutMinutes: Int?
        let logPath: String
    }

    struct RunOutcome: Sendable {
        let spec: RunSpec
        let status: String // succeeded | failed | timeout | spawn failed
        let exitCode: Int32?
        let spawnError: String?
    }

    /// Runs one agent process to completion. No EventKit, no AuditDB — safe
    /// to run concurrently; all recording happens serially in Phase C.
    private static func execute(_ spec: RunSpec) async -> RunOutcome {
        FileManager.default.createFile(atPath: spec.logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: spec.logPath)
        logHandle?.write(Data("""
        # dispatch #\(spec.ledgerId) \(ISO8601DateFormatter().string(from: Date()))
        # task \(spec.taskId): \(spec.title)
        # \(spec.argv.joined(separator: " "))\n\n
        """.utf8))
        defer { try? logHandle?.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = spec.argv
        if let runCwd = spec.runCwd { process.currentDirectoryURL = URL(fileURLWithPath: runCwd) }
        var env = ProcessInfo.processInfo.environment
        env["APPLE_TASKS_CALLER"] = "agent:\(spec.agentTag)"
        process.environment = env
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            return RunOutcome(spec: spec, status: "spawn failed", exitCode: nil,
                              spawnError: error.localizedDescription)
        }
        var timedOut = false
        if let minutes = spec.timeoutMinutes {
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
        let code = process.terminationStatus
        let status = timedOut ? "timeout" : (code == 0 ? "succeeded" : "failed")
        return RunOutcome(spec: spec, status: status, exitCode: code, spawnError: nil)
    }

    /// One-line run outcome for the ledger, plus (for succeeded worktree
    /// runs) up to 3 commit oneliners showing what the branch produced.
    private func trailer(ledgerId: Int64, status: String, exitCode: Int32?,
                         branch: String?, repo: String?, logPath: String?) -> String {
        var line = "[dispatch #\(ledgerId)] \(status)"
        if let exitCode { line += " exit=\(exitCode)" }
        if let branch { line += " branch=\(branch)" }
        if let logPath { line += " log=\(logPath)" }
        if status == "succeeded", let branch, let repo,
           let commits = Self.gitOutput(["log", "--oneline", "-3", branch, "--not", "HEAD"], repo: repo),
           !commits.isEmpty {
            line += "\n" + commits
        }
        return line
    }

    /// Append the run trailer to the task notes, re-fetching first because
    /// the agent may have edited the task meanwhile. Best-effort.
    private func appendNotesTrailer(store: Store, taskId: String, trailer: String) async {
        guard let current = try? await store.reminder(id: taskId) else { return }
        let existing = current.notes.map { $0.isEmpty ? "" : $0 + "\n\n" } ?? ""
        current.notes = existing + trailer
        try? store.save(current)
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

    private static func gitOutput(_ args: [String], repo: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(_ args: [String], repo: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        // Keep git chatter out of the command's JSON stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
