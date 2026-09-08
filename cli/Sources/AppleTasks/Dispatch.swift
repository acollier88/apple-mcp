import ArgumentParser
import EventKit
import Foundation

struct Dispatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Find open [auto] tasks and launch a configured agent for each. \
        A leading agent tag pins that lane; [auto] alone walks modelPrefs.auto \
        (any available worker). Config: ~/.config/apple-tasks/agents.json. \
        Dedupe via the dispatch ledger + a [dispatched] tag.
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

    @Flag(name: .customLong("quiet"), help: "Emit [] when this pass produced only repeat GC/skip reports identical to the previous pass (for launchd logs).")
    var quiet = false

    struct DispatchReport: Codable {
        let taskId: String
        let title: String
        let agent: String
        let cwd: String?
        let action: String
        let exitCode: Int?
        let runLog: String?
        let worktree: String?
        let command: String?
        let promptPreview: String?

        init(
            taskId: String,
            title: String,
            agent: String,
            cwd: String?,
            action: String,
            exitCode: Int?,
            runLog: String?,
            worktree: String?,
            command: String? = nil,
            promptPreview: String? = nil
        ) {
            self.taskId = taskId
            self.title = title
            self.agent = agent
            self.cwd = cwd
            self.action = action
            self.exitCode = exitCode
            self.runLog = runLog
            self.worktree = worktree
            self.command = command
            self.promptPreview = promptPreview
        }
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
        let env: [String: String]?
        let logPath: String
        /// How Phase B hands the prompt over (see AgentsConfig.Agent.promptVia).
        var promptVia: AgentsConfig.PromptVia = .argv
        /// Set only for `.stdin`: piped to the process after spawn.
        var stdinPrompt: String? = nil
        /// Set for `.stdin` and `.file`: `runs/<ledgerId>.prompt`.
        var promptFile: String? = nil
    }

    struct RunOutcome: Sendable {
        let spec: RunSpec
        let status: String // succeeded | failed | timeout | spawn failed
        let exitCode: Int32?
        let spawnError: String?
        var seat: AgentSeat.Info?
    }

    struct PlanResult {
        var specs: [RunSpec]
        var reports: [DispatchReport]
        var openReminderCount: Int
    }

    func run() async throws {
        let config = try AgentsConfig.load()
        if !AuditDB.shared.isAvailable {
            FileHandle.standardError.write(Data(
                "warning: audit ledger DB is unavailable — refusing to dispatch unledgered\n".utf8))
        }
        let requireAuto = config.requireAutoTag ?? true

        let store = Store()
        try await store.requestAccess()

        var reports: [DispatchReport] = []
        reports += await reapAndCollect(config: config, store: store)
        if reapOnly {
            emitReports(reports)
            return
        }
        let plan = try await plan(config: config, store: store, requireAuto: requireAuto)
        reports += plan.reports
        reports += await executeAll(plan.specs, config: config, store: store)
        if dryRun {
            let listLabel = listName ?? "all lists"
            reports.insert(
                DispatchReport(taskId: "-", title: listLabel, agent: "-", cwd: nil,
                               action: "dry-run scanned \(plan.openReminderCount) open reminders",
                               exitCode: nil, runLog: nil, worktree: nil),
                at: 0
            )
        }
        emitReports(reports)
    }
}
