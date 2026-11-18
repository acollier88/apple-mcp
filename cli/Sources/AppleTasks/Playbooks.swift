import ArgumentParser
import EventKit
import Foundation

/// Known fixes as code (#54). A healable finding takes the first rung that
/// fits: a playbook, an agent task, or a needs-human notice. Playbooks never
/// push, never delete a branch or a worktree, and never read or write
/// credential files.
///
/// Playbook ids match the detector signatures in `Diagnostics` (prefix
/// before `:`), so `doctor --enqueue-heals` can route a finding straight to
/// its playbook. Worktree retention is GC's job (`keepFailedWorktreeDays`,
/// opt-in `pendingReviewWorktreeDays`), and retry exhaustion is handled by
/// #77's accounting plus `dispatch-retry`; neither has a playbook.
enum Playbooks {
    static let logByteLimit = 512 * 1024 * 1024
    static let staleClaimDays = 14
    /// A running row is "hung" this long past its lane timeout.
    static let hungGraceSeconds: TimeInterval = 10 * 60

    enum Rung: Equatable {
        case playbook(String)
        case agent
        case needsHuman(String)
    }

    struct Book: Equatable {
        var id: String
        var blastRadius: String
        var needsHuman: Bool
    }

    enum Apply: Equatable {
        case none
        case notify(String)
        case rotate(String)
        /// Drop this Mac's `[dispatched]` claim from one reminder.
        case releaseClaim(taskId: String, newTitle: String)
        case argv([String])
    }

    struct Step: Equatable {
        var playbook: String
        var blastRadius: String
        var summary: String
        var apply: Apply
    }

    struct HungDispatcher: Equatable {
        var pid: Int32
        var command: String
        var ledgerId: Int
        var overSeconds: Int
    }

    struct Claim: Equatable {
        var taskId: String
        var title: String
        var ageDays: Int
    }

    struct Log: Equatable {
        var path: String
        var bytes: Int
    }

    struct Context {
        var launchAgentLoaded: Bool = true
        var plistPath: String = ""
        var guiDomain: String = "gui/0"
        var hung: HungDispatcher? = nil
        var claims: [Claim] = []
        var logs: [Log] = []
        var logsRoot: String = ""
    }

    static let catalog: [Book] = [
        Book(id: "dispatcher-hung", blastRadius: "SIGTERM one stuck apple-tasks dispatch process", needsHuman: false),
        Book(id: "launch-not-loaded", blastRadius: "bootstrap the com.apple-tasks.dispatch LaunchAgent", needsHuman: false),
        Book(id: "stale-claim", blastRadius: "this Mac's [dispatched] tag on reminders with no running dispatch", needsHuman: false),
        Book(id: "disk-logs", blastRadius: "rotate oversized files in the logs directory", needsHuman: false),
        Book(id: "deployment-drift", blastRadius: "notification only", needsHuman: true),
    ]

    static func rung(for fingerprint: String) -> Rung {
        guard let book = catalog.first(where: {
            fingerprint == $0.id || fingerprint.hasPrefix($0.id + ":")
        }) else { return .agent }
        return book.needsHuman ? .needsHuman(book.id) : .playbook(book.id)
    }

    /// Drop this Mac's claim tag. Another host's claim is left alone.
    static func titleWithoutOwnClaim(_ title: String) -> String? {
        let parsed = Tags.parse(title)
        let kept = parsed.tags.filter { !(ClaimTags.isDispatched($0) && ClaimTags.isOwn($0)) }
        guard kept.count != parsed.tags.count else { return nil }
        return Tags.compose(tags: kept, title: parsed.title)
    }

    /// The only commands a playbook may run.
    static func allowedArgv(_ argv: [String]) -> Bool {
        if argv.count == 4, argv[0] == "/bin/launchctl", argv[1] == "bootstrap",
           argv[2].hasPrefix("gui/"), argv[3].hasSuffix("/com.apple-tasks.dispatch.plist") {
            return true
        }
        if argv.count == 3, argv[0] == "/bin/kill", argv[1] == "-TERM",
           let pid = Int32(argv[2]), pid > 1 {
            return true
        }
        return false
    }

    static func plan(_ ctx: Context, only fingerprint: String? = nil) -> [Step] {
        var steps: [Step] = []
        func keep(_ id: String) -> Bool {
            guard let fingerprint else { return true }
            return fingerprint == id || fingerprint.hasPrefix(id + ":")
        }

        if keep("dispatcher-hung"), let hung = ctx.hung {
            let commandOK = hung.command.contains("apple-tasks") && hung.command.contains("dispatch")
                && !hung.command.contains("dispatch-")
            let argv = ["/bin/kill", "-TERM", String(hung.pid)]
            steps.append(Step(
                playbook: "dispatcher-hung", blastRadius: catalogNote("dispatcher-hung"),
                summary: commandOK
                    ? "dispatcher pid \(hung.pid) holds ledger #\(hung.ledgerId) \(hung.overSeconds)s past its timeout"
                    : "pid \(hung.pid) is not an apple-tasks dispatch process; not killing it",
                apply: commandOK && allowedArgv(argv) ? .argv(argv) : .none))
        }

        if keep("launch-not-loaded"), !ctx.launchAgentLoaded, !ctx.plistPath.isEmpty {
            let argv = ["/bin/launchctl", "bootstrap", ctx.guiDomain, ctx.plistPath]
            steps.append(Step(
                playbook: "launch-not-loaded", blastRadius: catalogNote("launch-not-loaded"),
                summary: "LaunchAgent com.apple-tasks.dispatch is not loaded",
                apply: allowedArgv(argv) ? .argv(argv) : .none))
        }

        if keep("stale-claim") {
            for claim in ctx.claims where claim.ageDays >= staleClaimDays {
                guard let rewritten = titleWithoutOwnClaim(claim.title) else { continue }
                steps.append(Step(
                    playbook: "stale-claim", blastRadius: catalogNote("stale-claim"),
                    summary: "claim on \(claim.taskId) is \(claim.ageDays) days old with no running dispatch",
                    apply: .releaseClaim(taskId: claim.taskId, newTitle: rewritten)))
            }
        }

        if keep("disk-logs") {
            for log in ctx.logs where log.bytes > logByteLimit && logIsInside(log.path, root: ctx.logsRoot) {
                steps.append(Step(
                    playbook: "disk-logs", blastRadius: catalogNote("disk-logs"),
                    summary: "\(log.path) is \(log.bytes) bytes",
                    apply: .rotate(log.path)))
            }
        }

        if keep("deployment-drift"), fingerprint != nil {
            steps.append(Step(
                playbook: "deployment-drift", blastRadius: catalogNote("deployment-drift"),
                summary: "the launchd binary does not match the source checkout",
                apply: .notify("The installed apple-tasks is not the checkout's build. Run make install when you mean to ship it. Nothing was changed.")))
        }
        return steps
    }

    /// Choose the dispatcher to signal: a `running` row past its lane timeout
    /// (plus grace) whose recorded dispatcher pid is still an apple-tasks
    /// dispatch process. Pure, so it can be tested without processes.
    static func hungDispatcher(
        rows: [(ledgerId: Int, dispatcherPid: Int?, ageSeconds: TimeInterval, timeoutSeconds: TimeInterval)],
        commandLine: (Int32) -> String?
    ) -> HungDispatcher? {
        for row in rows.sorted(by: { $0.ageSeconds > $1.ageSeconds }) {
            let over = row.ageSeconds - row.timeoutSeconds - hungGraceSeconds
            guard over > 0, let raw = row.dispatcherPid, raw > 1 else { continue }
            let pid = Int32(raw)
            guard let command = commandLine(pid) else { continue }
            return HungDispatcher(pid: pid, command: command, ledgerId: row.ledgerId, overSeconds: Int(over))
        }
        return nil
    }

    static func logIsInside(_ path: String, root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let folded = path.lowercased()
        if folded.contains("credential") || folded.contains(".env") || folded.contains("token")
            || folded.contains("secret") {
            return false
        }
        let rootURL = URL(fileURLWithPath: root).standardized.path
        let fileURL = URL(fileURLWithPath: path).standardized.path
        return fileURL.hasPrefix(rootURL + "/")
    }

    /// Rename an oversized log to `<name>.1` inside the logs directory.
    static func rotateLog(at path: String, root: String) throws -> String {
        guard logIsInside(path, root: root) else {
            throw AppleTasksError.saveFailed("refusing to rotate \(path)")
        }
        let source = URL(fileURLWithPath: path)
        let dest = URL(fileURLWithPath: path + ".1")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: source, to: dest)
        FileManager.default.createFile(atPath: source.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
        return dest.path
    }

    private static func catalogNote(_ id: String) -> String {
        catalog.first { $0.id == id }?.blastRadius ?? id
    }

    // MARK: - live

    static func logsRoot() -> URL {
        AppleTasksLayout.resolve().config.appendingPathComponent("logs", isDirectory: true)
    }

    /// Facts for `plan`. `store` is needed only for stale claims; nil skips them.
    static func liveContext(config: AgentsConfig?, store: Store?) async -> Context {
        var ctx = Context()
        let root = logsRoot()
        ctx.logsRoot = root.path
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            ctx.logs = names.map { name in
                let path = root.appendingPathComponent(name).path
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return Log(path: path, bytes: bytes)
            }
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.apple-tasks.dispatch.plist").path
        ctx.guiDomain = "gui/\(getuid())"
        if FileManager.default.fileExists(atPath: plist) {
            ctx.plistPath = plist
            if let result = try? ProcessRunner.run(
                URL(fileURLWithPath: "/bin/launchctl"),
                ["print", "\(ctx.guiDomain)/com.apple-tasks.dispatch"], timeout: 10) {
                ctx.launchAgentLoaded = result.status == 0 && !result.timedOut
            }
        }

        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let rows = AuditDB.shared.dispatchRows(status: "running", limit: 50).compactMap {
            row -> (ledgerId: Int, dispatcherPid: Int?, ageSeconds: TimeInterval, timeoutSeconds: TimeInterval)? in
            guard let started = isoFrac.date(from: row.startedAt) ?? iso.date(from: row.startedAt) else { return nil }
            let minutes = config?.agents[row.agent]?.timeoutMinutes ?? 60
            return (row.id, row.dispatcherPid, now.timeIntervalSince(started), TimeInterval(max(minutes, 1)) * 60)
        }
        ctx.hung = hungDispatcher(rows: rows) { pid in
            AgentProcess.looksLikeDispatcher(pid) ? AgentProcess.commandLine(pid) : nil
        }

        if let store {
            let open = (await store.reminders(in: nil)).filter { !$0.isCompleted }
            for reminder in open {
                let title = reminder.title ?? ""
                let tags = Tags.parse(title).tags
                guard tags.contains(where: { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }) else { continue }
                let taskId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
                guard !AuditDB.shared.hasActiveDispatch(taskId: taskId) else { continue }
                let modified = reminder.lastModifiedDate ?? reminder.creationDate ?? now
                let days = Int(now.timeIntervalSince(modified) / 86400)
                ctx.claims.append(Claim(taskId: taskId, title: title, ageDays: days))
            }
        }
        return ctx
    }

    /// Run one step. Throws when a command fails or is not allowed.
    static func apply(_ step: Step, store: Store?) async throws {
        switch step.apply {
        case .none:
            return
        case .notify(let body):
            _ = await Notifier.push(title: "apple-tasks needs you", body: body)
        case .rotate(let path):
            _ = try rotateLog(at: path, root: logsRoot().path)
        case .releaseClaim(let taskId, let newTitle):
            guard let store else { throw AppleTasksError.saveFailed("stale-claim needs Reminders access") }
            let reminder = try await store.reminder(id: taskId)
            reminder.title = newTitle
            try store.save(reminder)
            _ = NativeTags.remove(tags: [ClaimTags.dispatched, "dispatched"],
                                  externalId: reminder.calendarItemExternalIdentifier)
        case .argv(let argv):
            guard allowedArgv(argv) else {
                throw AppleTasksError.saveFailed("refusing argv: \(argv.joined(separator: " "))")
            }
            let result = try ProcessRunner.run(
                URL(fileURLWithPath: argv[0]), Array(argv.dropFirst()), timeout: 30)
            if result.timedOut || result.status != 0 {
                throw AppleTasksError.saveFailed(
                    "\(argv[0]) exited \(result.status): \(result.stderrString)")
            }
        }
        AuditDB.shared.record(command: "heal", detail: "run \(step.playbook): \(step.summary)")
    }
}

struct Heal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heal",
        abstract: "Run a known fix for a finding. Default is a dry run. Nothing pushes or deletes a branch."
    )

    @Flag(name: .long, help: "List playbooks and their blast radius.")
    var list = false

    @Flag(name: .customLong("dry-run"), help: "Show the steps without applying them.")
    var dryRun = false

    @Option(name: .customLong("run"), help: "Apply one playbook id or finding fingerprint.")
    var playbook: String?

    func run() async throws {
        if list || (playbook == nil && !dryRun) {
            emit(Playbooks.catalog)
            return
        }
        let applying = playbook != nil && !dryRun
        if applying {
            // A heal agent proposes; applying a playbook is doctor's or the human's call.
            try CallerGuard.enforce(
                CallerGuard.reviewRefusal(command: "heal --run", caller: CallerGuard.currentCaller),
                command: "heal", detail: playbook)
        }
        let needsStore = playbook.map { $0.hasPrefix("stale-claim") } ?? true
        var store: Store?
        if needsStore {
            let candidate = Store()
            if (try? await candidate.requestAccess()) != nil { store = candidate }
        }
        let steps = Playbooks.plan(
            await Playbooks.liveContext(config: try? AgentsConfig.load(), store: store), only: playbook)
        for step in steps {
            if applying {
                try await Playbooks.apply(step, store: store)
            } else {
                AuditDB.shared.record(command: "heal", detail: "dry-run \(step.playbook): \(step.summary)")
            }
        }
        emit(HealReportOut(mode: applying ? "run" : "dry-run", steps: steps))
    }
}

struct HealReportOut: Codable {
    var mode: String
    var steps: [Playbooks.Step]
}

extension Playbooks.Step: Codable {}
extension Playbooks.Apply: Codable {}
extension Playbooks.Book: Codable {}
