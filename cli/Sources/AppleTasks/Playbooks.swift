import ArgumentParser
import Foundation

/// Known fixes as code (#54). A healable finding takes the first rung that
/// fits: a playbook, an agent task, or a needs-human notice. Playbooks never
/// push, never delete a branch, and never read or write credential files.
enum Playbooks {
    static let logByteLimit = 512 * 1024 * 1024
    static let staleClaimDays = 14
    static let worktreeKeepDays = 7

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
        case retitle(old: String, new: String)
        case resetRetries(String)
        case argv([String])
    }

    struct Step: Equatable {
        var playbook: String
        var blastRadius: String
        var summary: String
        var apply: Apply
    }

    struct Context {
        var deploymentNote: String = ""
        var launchAgentLoaded: Bool = true
        var plistPath: String = ""
        var guiDomain: String = "gui/0"
        var hungPid: Int32? = nil
        var hungCommand: String = ""
        var claims: [(title: String, ageDays: Int)] = []
        var retries: [(taskId: String, summary: String, alreadyReset: Bool)] = []
        var worktrees: [(path: String, ageDays: Int)] = []
        var logs: [(path: String, bytes: Int)] = []
        var logsRoot: String = ""
    }

    static let catalog: [Book] = [
        Book(id: "dispatcher-hung", blastRadius: "one launchd job process", needsHuman: false),
        Book(id: "launchagent-unloaded", blastRadius: "reload one LaunchAgent", needsHuman: false),
        Book(id: "stale-claim", blastRadius: "this Mac's claim tag on a reminder title", needsHuman: false),
        Book(id: "retries-exhausted", blastRadius: "ignore older infrastructure failures once", needsHuman: false),
        Book(id: "worktree-retention", blastRadius: "remove a worktree directory; the branch stays", needsHuman: false),
        Book(id: "logs-oversize", blastRadius: "rotate one file under the logs directory", needsHuman: false),
        Book(id: "binary-drift", blastRadius: "notification only", needsHuman: true),
    ]

    static func rung(for fingerprint: String) -> Rung {
        guard let book = catalog.first(where: {
            fingerprint == $0.id || fingerprint.hasPrefix($0.id + ":")
        }) else { return .agent }
        return book.needsHuman ? .needsHuman(book.id) : .playbook(book.id)
    }

    static func isInfrastructure(_ summary: String) -> Bool {
        let folded = summary.lowercased()
        let markers = ["timeout", "dispatcher died", "network", "connection",
                       "unreachable", "502", "503"]
        return markers.contains { folded.contains($0) }
    }

    static func countsAfterReset(finishedAt: String?, ignoreBefore: String?) -> Bool {
        guard let ignoreBefore else { return true }
        guard let finishedAt else { return false }
        return finishedAt > ignoreBefore
    }

    /// Drop this Mac's claim tag. Another host's claim is left alone.
    static func titleWithoutOwnClaim(_ title: String) -> String? {
        let parsed = Tags.parse(title)
        let kept = parsed.tags.filter { !ClaimTags.isOwn($0) }
        guard kept.count != parsed.tags.count else { return nil }
        return Tags.compose(tags: kept, title: parsed.title)
    }

    static func allowedArgv(_ argv: [String]) -> Bool {
        let flat = argv.joined(separator: " ").lowercased()
        if flat.contains("push") || flat.contains("credential") || flat.contains(".env")
            || flat.contains("token") || flat.contains("secret") {
            return false
        }
        if argv.contains("branch") || argv.contains("-D") || argv.contains("-d") { return false }
        if argv.count == 5, argv[0] == "/usr/bin/git", argv[1] == "worktree",
           argv[2] == "remove", argv[3] == "--force", !argv[4].isEmpty {
            return true
        }
        if argv.count == 4, argv[0] == "/bin/launchctl", argv[1] == "bootstrap",
           argv[2].hasPrefix("gui/"), argv[3].hasSuffix("com.apple-tasks.dispatch.plist") {
            return true
        }
        if argv.count == 3, argv[0] == "/bin/kill", argv[1] == "-TERM", Int32(argv[2]) != nil {
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

        if keep("dispatcher-hung"), let pid = ctx.hungPid {
            let commandOK = ctx.hungCommand.contains("apple-tasks") && ctx.hungCommand.contains("dispatch")
            let argv = ["/bin/kill", "-TERM", String(pid)]
            steps.append(Step(
                playbook: "dispatcher-hung", blastRadius: catalogNote("dispatcher-hung"),
                summary: commandOK
                    ? "dispatcher pid \(pid) is past its limit"
                    : "pid \(pid) is not an apple-tasks dispatch process; not killing it",
                apply: commandOK && allowedArgv(argv) ? .argv(argv) : .none))
        }

        if keep("launchagent-unloaded"), !ctx.launchAgentLoaded, !ctx.plistPath.isEmpty {
            let argv = ["/bin/launchctl", "bootstrap", ctx.guiDomain, ctx.plistPath]
            steps.append(Step(
                playbook: "launchagent-unloaded", blastRadius: catalogNote("launchagent-unloaded"),
                summary: "LaunchAgent is not loaded",
                apply: allowedArgv(argv) ? .argv(argv) : .none))
        }

        if keep("stale-claim") {
            for claim in ctx.claims where claim.ageDays >= staleClaimDays {
                guard let rewritten = titleWithoutOwnClaim(claim.title) else { continue }
                steps.append(Step(
                    playbook: "stale-claim", blastRadius: catalogNote("stale-claim"),
                    summary: "claim is \(claim.ageDays) days old",
                    apply: .retitle(old: claim.title, new: rewritten)))
            }
        }

        if keep("retries-exhausted") {
            for row in ctx.retries where isInfrastructure(row.summary) && !row.alreadyReset {
                steps.append(Step(
                    playbook: "retries-exhausted", blastRadius: catalogNote("retries-exhausted"),
                    summary: "infrastructure failures for \(row.taskId) will be ignored once",
                    apply: .resetRetries(row.taskId)))
            }
        }

        if keep("worktree-retention") {
            for tree in ctx.worktrees where tree.ageDays >= worktreeKeepDays {
                let argv = ["/usr/bin/git", "worktree", "remove", "--force", tree.path]
                steps.append(Step(
                    playbook: "worktree-retention", blastRadius: catalogNote("worktree-retention"),
                    summary: "worktree \(tree.path) is \(tree.ageDays) days old; branch is kept",
                    apply: allowedArgv(argv) ? .argv(argv) : .none))
            }
        }

        if keep("logs-oversize") {
            for log in ctx.logs where log.bytes > logByteLimit && logIsInside(log.path, root: ctx.logsRoot) {
                steps.append(Step(
                    playbook: "logs-oversize", blastRadius: catalogNote("logs-oversize"),
                    summary: "\(log.path) is \(log.bytes) bytes",
                    apply: .rotate(log.path)))
            }
        }

        if keep("binary-drift"),
           ctx.deploymentNote.localizedCaseInsensitiveContains("behind")
            || ctx.deploymentNote.localizedCaseInsensitiveContains("predates") {
            steps.append(Step(
                playbook: "binary-drift", blastRadius: catalogNote("binary-drift"),
                summary: ctx.deploymentNote,
                apply: .notify("Installed apple-tasks is behind the checkout. Run make install. No file was changed.")))
        }
        return steps
    }

    static func logIsInside(_ path: String, root: String) -> Bool {
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
        FileManager.default.createFile(atPath: source.path, contents: Data())
        return dest.path
    }

    static func applyReset(_ taskId: String, db: AuditDB = .shared) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        _ = db.setState("heal.retryReset.\(taskId)", stamp)
    }

    private static func catalogNote(_ id: String) -> String {
        catalog.first { $0.id == id }?.blastRadius ?? id
    }
}

struct Heal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heal",
        abstract: "Run a known fix for a finding. Default is a dry run. Nothing pushes or deletes a branch."
    )

    @Flag(name: .long, help: "Open healable findings and which rung they are on.")
    var report = false

    @Flag(name: .long, help: "List playbooks and their blast radius.")
    var list = false

    @Flag(name: .customLong("dry-run"), help: "Show the steps. This is the default.")
    var dryRun = false

    @Option(name: .customLong("run"), help: "Apply one playbook id or fingerprint prefix.")
    var playbook: String?

    func run() async throws {
        if report {
            let rows = AuditDB.shared.findings(state: "open", findingClass: "healable", limit: 100)
            emit(HealPolicy.report(rows) { AuditDB.shared.getState(HealPolicy.levelKey($0)) })
            return
        }
        if list || (playbook == nil && !dryRun) {
            emit(Playbooks.catalog)
            if playbook == nil { return }
        }
        let steps = Playbooks.plan(Self.liveContext(), only: playbook)
        let applying = playbook != nil && !dryRun
        var ran: [Playbooks.Step] = []
        for step in steps {
            if applying {
                try await Self.apply(step)
            }
            ran.append(step)
            let mode = applying ? "run" : "dry-run"
            AuditDB.shared.record(command: "heal", detail: "\(mode) \(step.playbook): \(step.summary)")
        }
        emit(HealReportOut(mode: applying ? "run" : "dry-run", steps: ran))
    }

    private static func apply(_ step: Playbooks.Step) async throws {
        switch step.apply {
        case .none, .retitle:
            return
        case .notify(let body):
            _ = await Notifier.push(title: "apple-tasks needs you", body: body)
        case .rotate(let path):
            _ = try Playbooks.rotateLog(at: path, root: logsRoot().path)
        case .resetRetries(let taskId):
            Playbooks.applyReset(taskId)
        case .argv(let argv):
            guard Playbooks.allowedArgv(argv) else {
                throw AppleTasksError.saveFailed("refusing argv: \(argv.joined(separator: " "))")
            }
            let result = try ProcessRunner.run(
                URL(fileURLWithPath: argv[0]), Array(argv.dropFirst()), timeout: 30)
            if result.timedOut || result.status != 0 {
                throw AppleTasksError.saveFailed(
                    "\(argv[0]) exited \(result.status): \(result.stderrString)")
            }
        }
    }

    static func logsRoot() -> URL {
        let override = ProcessInfo.processInfo.environment["APPLE_TASKS_CONFIG_DIR"]
        let base = override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/apple-tasks")
        return base.appendingPathComponent("logs", isDirectory: true)
    }

    static func liveContext() -> Playbooks.Context {
        var ctx = Playbooks.Context()
        ctx.logsRoot = logsRoot().path
        let root = logsRoot()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            ctx.logs = names.map { name in
                let path = root.appendingPathComponent(name).path
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return (path: path, bytes: bytes)
            }
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.apple-tasks.dispatch.plist").path
        ctx.plistPath = plist
        ctx.guiDomain = "gui/\(getuid())"
        ctx.launchAgentLoaded = true
        if FileManager.default.fileExists(atPath: plist),
           let result = try? ProcessRunner.run(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["print", "\(ctx.guiDomain)/com.apple-tasks.dispatch"],
            timeout: 10) {
            ctx.launchAgentLoaded = result.status == 0 && !result.timedOut
        }
        return ctx
    }
}

struct HealReportOut: Codable {
    var mode: String
    var steps: [Playbooks.Step]
}

extension Playbooks.Step: Codable {}
extension Playbooks.Apply: Codable {}
extension Playbooks.Book: Codable {}
