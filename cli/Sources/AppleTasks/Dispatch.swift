import ArgumentParser
import Darwin
import EventKit
import Foundation

struct Dispatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Find open [auto] tasks and launch a configured agent for each. \
        A leading agent tag pins that lane; [auto] alone walks modelPrefs.auto \
        (any available worker). Config: ~/.config/apple-tasks/agents.json. \
        Dedupe via the dispatch ledger + a [dispatched] tag.
        """,
        discussion: """
        dispatch-pause stops new claims; reap and worktree GC still run. \
        --reap-only ignores the pause. --dry-run still plans and prefixes \
        a 'paused until <ISO> [(reason)]' report so you see both. Without \
        --dry-run the pass stops after reap/GC and appends that report. \
        --quiet (launchd) emits the paused report only when until/reason \
        changed since the last pass (dispatch.pauseLastReported); an \
        unchanged pause, an empty pass, or repeat GC/skip noise prints \
        nothing, so logs do not fill with 'paused' lines or []. \
        Pass start and end are timestamped on stderr either way.
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

    @Flag(name: .customLong("quiet"), help: """
        Print nothing when this pass is empty or only repeats the previous \
        pass's GC/skip/gate/schedule noise (for launchd logs). Real failures \
        and dispatch lines are always printed. A paused report is included \
        only when the pause until/reason changed since the last pass.
        """)
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
        /// envMode / envPassthrough / lane env, applied by `AgentEnv.build`.
        let envPolicy: AgentEnv.Policy
        /// argv with the prompt replaced by `ledgerPromptMarker`, for the
        /// run-log header (the ledger row stores the same shape).
        let displayCommand: String
        let logPath: String
        /// How Phase B hands the prompt over (see AgentsConfig.Agent.promptVia).
        var promptVia: AgentsConfig.PromptVia = .argv
        /// Set only for `.stdin`: piped to the process after spawn.
        var stdinPrompt: String? = nil
        /// Set for `.stdin` and `.file`: `runs/<ledgerId>.prompt`.
        var promptFile: String? = nil
        /// Auto-pool chose this lane; stamp it onto the title when the
        /// agent actually starts so retries pin the provider that ran.
        var stampLane: Bool = false
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

    /// Live dispatch is refused when a dispatched agent is the caller.
    /// `--dry-run` and `--reap-only` stay allowed (inspect / housekeeping).
    static func recursionRefusal(caller: String?, dryRun: Bool, reapOnly: Bool) -> String? {
        guard let caller, caller.hasPrefix("agent:") else { return nil }
        if dryRun || reapOnly { return nil }
        return "dispatch is not available to dispatched agents (APPLE_TASKS_CALLER=\(caller)); use --dry-run to inspect"
    }

    func run() async throws {
        if let message = Self.recursionRefusal(
            caller: ProcessInfo.processInfo.environment["APPLE_TASKS_CALLER"],
            dryRun: dryRun, reapOnly: reapOnly) {
            throw AppleTasksError.invalidInput(message)
        }
        let config = try AgentsConfig.load()
        Self.passLog("dispatch pass start quiet=\(quiet) dryRun=\(dryRun)")
        defer { Self.passLog("dispatch pass end") }
        // tools/launchd starts `dispatch --quiet` on StartInterval and will
        // not start another pass while this process is running. Arm the cap
        // here, not by editing the installed plist.
        let passWatchdog = PassWatchdog.arm(minutes: config.resolvedMaxPassMinutes)
        defer { passWatchdog.disarm() }
        if !dryRun {
            let layout = AppleTasksLayout.resolve()
            let migration = AppleTasksLayout.migrateRuntime(from: layout.config, to: layout.support)
            if !migration.notes.isEmpty {
                let text = migration.notes.joined(separator: "; ")
                FileHandle.standardError.write(Data("apple-tasks runtime migration: \(text)\n".utf8))
            }
        }
        if !AuditDB.shared.isAvailable {
            FileHandle.standardError.write(Data(
                "warning: audit ledger DB is unavailable — refusing to dispatch unledgered\n".utf8))
        }
        let requireAuto = config.requireAutoTag ?? true

        let store = Store()
        try await store.requestAccess()

        var reports: [DispatchReport] = []
        // A dry run plans only. Reaping and GC write the ledger, tags, and
        // worktrees; doing that before the flag is checked made --dry-run
        // mutate the machine (#44).
        if !dryRun {
            reports += await reapAndCollect(config: config, store: store)
            // Nudge once per distinct pending-review set. Dry-run stays quiet;
            // a paused or reap-only pass still notifies (the backlog is not a
            // new claim). Repeats stay quiet until a row, branch, or commit changes.
            await PendingReview.notifyIfChanged(items: PendingReview.items(), db: .shared)
        }
        if reapOnly {
            emitReports(reports)
            return
        }

        let pause = Self.resolvedPause(db: .shared)
        if let pause, !dryRun {
            attachPausedReport(&reports, pause: pause)
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
        if let pause {
            reports.insert(pause.report, at: 0)
        }
        emitReports(reports)
    }

    /// Append the paused-until report, or omit it under `--quiet` when the
    /// pause identity matches `dispatch.pauseLastReported`.
    func attachPausedReport(_ reports: inout [DispatchReport], pause: PauseState) {
        let last = Self.nonempty(AuditDB.shared.getState(Self.pauseLastReportedKey))
        guard Self.shouldEmitPausedReport(quiet: quiet, lastReported: last, pause: pause) else {
            return
        }
        reports.append(pause.report)
        if !dryRun {
            AuditDB.shared.setState(Self.pauseLastReportedKey, pause.identity)
        }
    }

    /// Timestamped line on stderr. launchd keeps that file separate from the
    /// JSON stdout log, and stdout is only written when the pass finishes,
    /// so a hung pass would otherwise leave no trace (#44).
    static func passLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }

    /// Wording for a `running` row whose agent pid is already gone.
    static func orphanedDispatchSummary(dispatcherAlive: Bool) -> String {
        if dispatcherAlive {
            return "agent exited but dispatcher never recorded the result"
        }
        return "dispatcher process is gone"
    }
}

/// Exits the process if one `dispatch` invocation outlives its cap. `defer`
/// disarms it on the normal path. `_exit` is deliberate: a stuck pass may
/// hold locks the ordinary `exit` would try to take.
private final class PassWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var disarmed = false

    static func arm(minutes: Int) -> PassWatchdog {
        let watchdog = PassWatchdog()
        let seconds = TimeInterval(max(minutes, 1) * 60)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            watchdog.fire(minutes: max(minutes, 1))
        }
        return watchdog
    }

    func disarm() {
        lock.lock()
        disarmed = true
        lock.unlock()
    }

    private func fire(minutes: Int) {
        lock.lock()
        let skip = disarmed
        lock.unlock()
        guard !skip else { return }
        let message = "apple-tasks dispatch: pass exceeded \(minutes)m; exiting so launchd can start the next pass\n"
        FileHandle.standardError.write(Data(message.utf8))
        AgentProcess.killTracked()
        _exit(75)
    }
}
