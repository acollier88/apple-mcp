import ArgumentParser
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

    static let statuses = ["running", "succeeded", "failed", "timeout", "cancelled", "aborted", "pending-review"]

    @Option(help: "Filter: running | succeeded | failed | timeout | cancelled | aborted | pending-review.")
    var status: String?

    @Flag(name: .customLong("pending-review"),
          help: "Alias for --status pending-review: unmerged succeeded worktree branches.")
    var pendingReview = false

    @Option(help: "Max rows (default 50, newest first).")
    var limit: Int = 50

    func run() async throws {
        if pendingReview || status == "pending-review" {
            emit(PendingReview.items(limit: limit))
            return
        }
        if let status {
            guard Self.statuses.contains(status) else {
                throw AppleTasksError.invalidInput(
                    "status must be \(Self.statuses.joined(separator: " | "))")
            }
        }
        emit(AuditDB.shared.dispatchRows(status: status, limit: limit))
    }
}

/// Cancel a still-running ledger row: signal the agent, mark `cancelled`,
/// shed this Mac's [dispatched] claim. Does not write [failed] (a cancel is
/// a human decision and must not trip retry/backoff). Worktree is left for GC.
struct DispatchCancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-cancel",
        abstract: """
        Cancel a running dispatch by ledger id: signal the agent process, \
        mark the row cancelled, shed this Mac's [dispatched] claim. Leaves \
        the worktree for GC (keepFailedWorktreeDays).
        """
    )

    @Argument(help: "Ledger row id (apple-tasks dispatches).")
    var ledgerId: Int64

    struct Result: Codable {
        let id: Int
        let taskId: String
        let agent: String
        let status: String
        let process: String
        let tagShed: Bool
    }

    struct NotRunning: Codable {
        let id: Int
        let status: String
        let cancelled: Bool
        let note: String
    }

    func run() async throws {
        guard let row = AuditDB.shared.dispatchRow(id: ledgerId) else {
            throw AppleTasksError.invalidInput("no dispatch ledger row #\(ledgerId)")
        }
        if row.status != "running" {
            emit(NotRunning(id: row.id, status: row.status, cancelled: false, note: "not running"))
            return
        }

        let store = Store()
        let ready = (try? await store.requestAccess()) != nil
        emit(await Dispatch.cancelRunning(row: row, store: ready ? store : nil))
    }
}

extension Dispatch {
    /// Signal the agent, mark the row `cancelled`, shed this Mac's claim and
    /// append the notes trailer. `store` nil (no Reminders access) still
    /// cancels the ledger row and the process.
    static func cancelRunning(row: AuditDB.DispatchRow, store: Store?) async -> DispatchCancel.Result {
        let ledgerId = Int64(row.id)
        var processNote = "not found"
        if let pid = row.pid,
           AgentProcess.looksLikeOurs(Int32(pid), ledgerId: ledgerId,
                                      taskId: row.taskId, agent: row.agent) {
            processNote = AgentProcess.terminate(Int32(pid))
        }

        AuditDB.shared.finishDispatch(
            id: ledgerId, status: "cancelled", exitCode: -1,
            summary: "cancelled by \(AuditDB.caller)")

        var tagShed = false
        var title = row.command
        var list: String?
        if let store {
            tagShed = await shedOwnDispatchedClaim(store: store, taskId: row.taskId)
            if let reminder = try? await store.reminder(id: row.taskId) {
                let parsed = Tags.parse(reminder.title ?? "")
                title = parsed.title.isEmpty ? (reminder.title ?? row.command) : parsed.title
                list = reminder.calendar?.title
            }
            let trailerText = trailer(
                ledgerId: ledgerId, status: "cancelled", exitCode: -1,
                branch: nil, repo: row.cwd, logPath: row.runLogPath, seat: nil)
            await appendNotesTrailer(store: store, taskId: row.taskId, trailer: trailerText)
        }

        AuditDB.shared.record(command: "dispatch-cancel", taskId: row.taskId,
                              list: list, detail: "\(row.agent): \(title)", result: "ok")
        return DispatchCancel.Result(id: row.id, taskId: row.taskId, agent: row.agent,
                                     status: "cancelled", process: processNote, tagShed: tagShed)
    }
}

/// Discard a succeeded worktree branch: force-remove the worktree, delete the
/// agent branch, mark the ledger row reviewed. Idempotent if already reviewed.
struct DispatchDiscard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-discard",
        abstract: """
        Discard a succeeded worktree branch by ledger id: force-remove the \
        worktree, delete the agent/<agent>-<id> branch, mark the row reviewed.
        """
    )

    @Argument(help: "Ledger row id (apple-tasks dispatches --status pending-review).")
    var ledgerId: Int64

    struct DiscardResult: Codable {
        let id: Int
        let branch: String
        let worktreeRemoved: Bool
        let branchDeleted: Bool
    }

    struct AlreadyReviewed: Codable {
        let id: Int
        let discarded: Bool
        let note: String
    }

    func run() async throws {
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "dispatch-discard", caller: CallerGuard.currentCaller),
            command: "dispatch-discard", detail: nil)
        guard let row = AuditDB.shared.dispatchRow(id: ledgerId) else {
            throw AppleTasksError.invalidInput("no dispatch ledger row #\(ledgerId)")
        }
        if row.reviewedAt != nil {
            emit(AlreadyReviewed(id: row.id, discarded: false, note: "already reviewed"))
            return
        }
        guard row.status == "succeeded", row.worktree != nil else {
            let message = row.status != "succeeded"
                ? "dispatch #\(row.id) is \(row.status), not a succeeded worktree run"
                : "dispatch #\(row.id) has no worktree on record"
            throw AppleTasksError.invalidInput(message)
        }
        emit(Self.discard(row: row, db: .shared))
    }

    /// Git + ledger steps so tests can exercise discard without ArgumentParser.
    static func discard(row: AuditDB.DispatchRow, db: AuditDB) -> DiscardResult {
        let branch = row.branch ?? "agent/\(row.agent)-\(row.id)"
        var worktreeRemoved = false
        var branchDeleted = false
        if let repo = row.cwd, !repo.isEmpty {
            if let wt = row.worktree {
                _ = Dispatch.runGit(["worktree", "remove", "--force", wt], repo: repo)
                worktreeRemoved = !FileManager.default.fileExists(atPath: wt)
            }
            _ = Dispatch.runGit(["branch", "-D", branch], repo: repo)
            branchDeleted = Dispatch.runGit(
                ["rev-parse", "--verify", "--quiet", branch], repo: repo) != 0
        } else if let wt = row.worktree {
            worktreeRemoved = !FileManager.default.fileExists(atPath: wt)
        }
        db.clearWorktree(id: Int64(row.id))
        db.markReviewed(id: Int64(row.id))
        db.record(command: "dispatch-discard", taskId: row.taskId,
                  detail: "\(row.agent): \(branch)", result: "ok")
        return DiscardResult(id: row.id, branch: branch,
                             worktreeRemoved: worktreeRemoved, branchDeleted: branchDeleted)
    }
}

/// Accept a succeeded worktree branch: fast-forward merge it when HEAD can
/// take it cleanly, otherwise open a GitHub pull request with `gh`.
/// `--dry-run` reports the choice and does not merge, push, or call `gh`.
struct DispatchAccept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-accept",
        abstract: """
        Accept a succeeded worktree branch by ledger id: fast-forward merge \
        it when the checkout is clean and the branch is a fast-forward of \
        HEAD, otherwise open a GitHub pull request with gh. --dry-run reports \
        that choice without merging or contacting GitHub.
        """
    )

    @Argument(help: "Ledger row id (apple-tasks dispatches --status pending-review).")
    var ledgerId: Int64

    @Flag(name: .customLong("dry-run"),
          help: "Report merge vs pull-request without merging, pushing, or calling gh.")
    var dryRun = false

    struct AcceptResult: Codable {
        let id: Int
        let branch: String
        let action: String
        let reason: String
        let dryRun: Bool
        let merged: Bool
        let worktreeRemoved: Bool
        let branchDeleted: Bool
        let pullRequestURL: String?
    }

    struct AlreadyReviewed: Codable {
        let id: Int
        let accepted: Bool
        let note: String
    }

    /// Merge when the agent branch is a fast-forward and the destination
    /// checkout is clean. Anything else is a pull request — diverged history
    /// and a dirty tree both refuse a silent merge.
    struct Plan: Equatable {
        enum Action: String, Equatable {
            case merge
            case pullRequest = "pull-request"
        }
        let action: Action
        let reason: String
    }

    struct Probe: Equatable {
        let branchExists: Bool
        let alreadyMerged: Bool
        let fastForward: Bool
        let clean: Bool
        /// Branch checked out in the repo (`symbolic-ref`); nil when detached.
        var target: String? = nil
    }

    static func plan(fastForward: Bool, clean: Bool, target: String? = "main") -> Plan {
        // A detached HEAD has no branch to advance; merging there would leave
        // the agent's commits on no branch at all.
        guard target != nil else {
            return Plan(action: .pullRequest, reason: "HEAD is detached")
        }
        if fastForward && clean {
            return Plan(action: .merge, reason: "clean fast-forward of \(target ?? "HEAD")")
        }
        if !fastForward {
            return Plan(action: .pullRequest, reason: "not a fast-forward of HEAD")
        }
        return Plan(action: .pullRequest, reason: "working tree is not clean")
    }

    static func probe(branch: String, repo: String) -> Probe {
        let branchExists = Dispatch.runGit(
            ["rev-parse", "--verify", "--quiet", branch], repo: repo) == 0
        let alreadyMerged = branchExists && Dispatch.runGit(
            ["merge-base", "--is-ancestor", branch, "HEAD"], repo: repo) == 0
        let fastForward = branchExists && !alreadyMerged && Dispatch.runGit(
            ["merge-base", "--is-ancestor", "HEAD", branch], repo: repo) == 0
        let clean: Bool
        if let porcelain = Dispatch.gitOutput(["status", "--porcelain"], repo: repo) {
            clean = porcelain.isEmpty
        } else {
            clean = false
        }
        let target = Dispatch.gitOutput(["symbolic-ref", "--short", "-q", "HEAD"], repo: repo)
            .flatMap { $0.isEmpty ? nil : $0 }
        return Probe(branchExists: branchExists, alreadyMerged: alreadyMerged,
                     fastForward: fastForward, clean: clean, target: target)
    }

    static func gitPushArguments(branch: String) -> [String] {
        ["push", "-u", "origin", "--", branch]
    }

    static func ghPullRequestArguments(branch: String, base: String?, title: String, body: String) -> [String] {
        var args = ["pr", "create", "--head", branch, "--title", title, "--body", body]
        if let base, !base.isEmpty, base != "HEAD" {
            args += ["--base", base]
        }
        return args
    }

    static func pullRequestTitle(row: AuditDB.DispatchRow) -> String {
        if let summary = row.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let oneLine = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? summary
            return String(oneLine.prefix(120))
        }
        return "\(row.agent): \(row.taskId)"
    }

    static func pullRequestBody(row: AuditDB.DispatchRow, branch: String, commits: [String], reason: String) -> String {
        var lines = [
            "Agent `\(row.agent)` finished ledger #\(row.id) on `\(branch)`.",
            "",
            "Opened by `apple-tasks dispatch-accept` (\(reason)).",
        ]
        if !commits.isEmpty {
            lines.append("")
            lines.append(contentsOf: commits.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    func run() async throws {
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "dispatch-accept", caller: CallerGuard.currentCaller),
            command: "dispatch-accept", detail: nil)
        guard let row = AuditDB.shared.dispatchRow(id: ledgerId) else {
            throw AppleTasksError.invalidInput("no dispatch ledger row #\(ledgerId)")
        }
        switch try Self.accept(row: row, db: .shared, dryRun: dryRun) {
        case .alreadyReviewed(let payload):
            emit(payload)
        case .accepted(let payload):
            emit(payload)
        }
    }

    enum Outcome {
        case alreadyReviewed(AlreadyReviewed)
        case accepted(AcceptResult)
    }

    /// Git + ledger steps so tests can exercise accept without ArgumentParser.
    /// The pull-request path pushes and calls `gh` only when `dryRun` is false.
    static func accept(row: AuditDB.DispatchRow, db: AuditDB, dryRun: Bool) throws -> Outcome {
        if row.reviewedAt != nil {
            return .alreadyReviewed(AlreadyReviewed(id: row.id, accepted: false, note: "already reviewed"))
        }
        guard row.status == "succeeded", row.worktree != nil else {
            let message = row.status != "succeeded"
                ? "dispatch #\(row.id) is \(row.status), not a succeeded worktree run"
                : "dispatch #\(row.id) has no worktree on record"
            throw AppleTasksError.invalidInput(message)
        }
        let branch = row.branch ?? "agent/\(row.agent)-\(row.id)"
        guard let repo = row.cwd, !repo.isEmpty else {
            throw AppleTasksError.invalidInput("dispatch #\(row.id) has no repo on record")
        }
        guard Dispatch.runGit(["rev-parse", "--git-dir"], repo: repo) == 0 else {
            throw AppleTasksError.invalidInput("dispatch #\(row.id) cwd is not a git repo")
        }
        let probe = probe(branch: branch, repo: repo)
        guard probe.branchExists else {
            throw AppleTasksError.invalidInput("branch \(branch) does not exist")
        }

        if probe.alreadyMerged {
            if dryRun {
                return .accepted(AcceptResult(
                    id: row.id, branch: branch, action: Plan.Action.merge.rawValue,
                    reason: "already merged", dryRun: true, merged: false,
                    worktreeRemoved: false, branchDeleted: false, pullRequestURL: nil))
            }
            let settled = settle(row: row, branch: branch, repo: repo, db: db, deleteBranch: true)
            db.record(command: "dispatch-accept", taskId: row.taskId,
                      detail: "\(row.agent): \(branch) already merged", result: "ok")
            return .accepted(AcceptResult(
                id: row.id, branch: branch, action: Plan.Action.merge.rawValue,
                reason: "already merged", dryRun: false, merged: true,
                worktreeRemoved: settled.worktreeRemoved, branchDeleted: settled.branchDeleted,
                pullRequestURL: nil))
        }

        let choice = plan(fastForward: probe.fastForward, clean: probe.clean, target: probe.target)
        switch choice.action {
        case .merge:
            if dryRun {
                return .accepted(AcceptResult(
                    id: row.id, branch: branch, action: choice.action.rawValue,
                    reason: choice.reason, dryRun: true, merged: false,
                    worktreeRemoved: false, branchDeleted: false, pullRequestURL: nil))
            }
            let merge = try ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/git"),
                ["-C", repo, "merge", "--ff-only", "--", branch],
                timeout: 120)
            guard !merge.timedOut, merge.status == 0 else {
                let detail = merge.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppleTasksError.automationFailed(
                    "git merge --ff-only \(branch): \(detail.isEmpty ? "merge failed" : detail)")
            }
            let settled = settle(row: row, branch: branch, repo: repo, db: db, deleteBranch: true)
            db.record(command: "dispatch-accept", taskId: row.taskId,
                      detail: "\(row.agent): merged \(branch)", result: "ok")
            return .accepted(AcceptResult(
                id: row.id, branch: branch, action: choice.action.rawValue,
                reason: choice.reason, dryRun: false, merged: true,
                worktreeRemoved: settled.worktreeRemoved, branchDeleted: settled.branchDeleted,
                pullRequestURL: nil))
        case .pullRequest:
            if dryRun {
                return .accepted(AcceptResult(
                    id: row.id, branch: branch, action: choice.action.rawValue,
                    reason: choice.reason, dryRun: true, merged: false,
                    worktreeRemoved: false, branchDeleted: false, pullRequestURL: nil))
            }
            let commits = Dispatch.gitOutput(
                ["log", "--oneline", "-n", "3", "HEAD..\(branch)"], repo: repo)?
                .split(whereSeparator: \.isNewline).map(String.init) ?? []
            let url = try openPullRequest(
                branch: branch, repo: repo,
                title: pullRequestTitle(row: row),
                body: pullRequestBody(row: row, branch: branch, commits: commits, reason: choice.reason))
            // The branch stays (it is the PR head). The checkout can go.
            let settled = settle(row: row, branch: branch, repo: repo, db: db, deleteBranch: false)
            db.record(command: "dispatch-accept", taskId: row.taskId,
                      detail: "\(row.agent): \(branch) \(url)", result: "ok")
            return .accepted(AcceptResult(
                id: row.id, branch: branch, action: choice.action.rawValue,
                reason: choice.reason, dryRun: false, merged: false,
                worktreeRemoved: settled.worktreeRemoved, branchDeleted: false,
                pullRequestURL: url))
        }
    }

    private static func settle(
        row: AuditDB.DispatchRow, branch: String, repo: String, db: AuditDB, deleteBranch: Bool
    ) -> (worktreeRemoved: Bool, branchDeleted: Bool) {
        var worktreeRemoved = true
        if let wt = row.worktree {
            if FileManager.default.fileExists(atPath: wt) {
                _ = Dispatch.runGit(["worktree", "remove", "--force", wt], repo: repo)
            }
            worktreeRemoved = !FileManager.default.fileExists(atPath: wt)
        }
        var branchDeleted = false
        if deleteBranch {
            _ = Dispatch.runGit(["branch", "-d", branch], repo: repo)
            branchDeleted = Dispatch.runGit(
                ["rev-parse", "--verify", "--quiet", branch], repo: repo) != 0
        }
        if worktreeRemoved {
            db.clearWorktree(id: Int64(row.id))
        }
        db.markReviewed(id: Int64(row.id))
        return (worktreeRemoved, branchDeleted)
    }

    static func ghExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func firstURL(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map(String.init).first {
            $0.hasPrefix("https://") || $0.hasPrefix("http://")
        }
    }

    /// Push `branch` to origin and open a PR (or return the URL of one that
    /// already exists). Tests cover the decision and the argument lists;
    /// this function is the network path and is not called under `--dry-run`.
    static func openPullRequest(branch: String, repo: String, title: String, body: String) throws -> String {
        let push = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            ["-C", repo] + gitPushArguments(branch: branch),
            timeout: 180)
        guard !push.timedOut, push.status == 0 else {
            let detail = push.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppleTasksError.automationFailed(
                "git push \(branch): \(detail.isEmpty ? "push failed" : detail)")
        }
        guard let gh = ghExecutable() else {
            throw AppleTasksError.automationFailed(
                "gh CLI not found (brew install gh; then gh auth login)")
        }
        let repoURL = URL(fileURLWithPath: repo)
        let view = try ProcessRunner.run(
            gh, ["pr", "view", branch, "--json", "url", "--jq", ".url"],
            timeout: 60, directory: repoURL)
        if view.status == 0, let url = firstURL(in: view.stdoutString) {
            return url
        }
        let base = Dispatch.gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], repo: repo)
        let created = try ProcessRunner.run(
            gh, ghPullRequestArguments(branch: branch, base: base, title: title, body: body),
            timeout: 180, directory: repoURL)
        guard !created.timedOut, created.status == 0 else {
            let detail = created.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppleTasksError.automationFailed(
                "gh pr create: \(detail.isEmpty ? "gh failed" : detail)")
        }
        guard let url = firstURL(in: created.stdoutString) else {
            throw AppleTasksError.automationFailed("gh pr create returned no URL")
        }
        return url
    }
}

/// Manually re-queue a failed task: shed every [failed] tag and restore
/// [auto] so the next dispatch pass picks it up as a fresh run. A human
/// retry bypasses maxRetries/backoff (those gate only [failed] tasks).
struct DispatchRetry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-retry",
        abstract: """
        Re-queue a failed task by task id or ledger id: remove its [failed] \
        tags and restore [auto] so the next dispatch pass runs it. Bypasses \
        maxRetries/backoff. Refused while the task is claimed or running.
        """
    )

    @Argument(help: "Task id, or a ledger row id (apple-tasks dispatches --status failed).")
    var target: String

    struct Result: Codable {
        let taskId: String
        let title: String
        let removedTags: [String]
        let addedAuto: Bool
        let fromLedgerId: Int?
    }

    /// Tag rewrite for a retry; nil when the task still carries a claim.
    static func requeueTags(_ tags: [String]) -> (tags: [String], removed: [String], addedAuto: Bool)? {
        if tags.contains(where: ClaimTags.isDispatched) { return nil }
        let removed = tags.filter(ClaimTags.isFailed)
        var kept = tags.filter { !ClaimTags.isFailed($0) }
        let addedAuto = !kept.contains { $0.lowercased() == "auto" }
        if addedAuto { kept.insert("auto", at: 0) }
        return (kept, removed, addedAuto)
    }

    func run() async throws {
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "dispatch-retry", caller: CallerGuard.currentCaller),
            command: "dispatch-retry", detail: nil)
        var taskId = target
        var ledgerId: Int?
        if target.allSatisfy(\.isNumber), let id = Int64(target),
           let row = AuditDB.shared.dispatchRow(id: id) {
            taskId = row.taskId
            ledgerId = row.id
        }
        if AuditDB.shared.hasActiveDispatch(taskId: taskId) {
            throw AppleTasksError.invalidInput("task \(taskId) has a running dispatch — cancel it first")
        }

        let store = Store()
        try await store.requestAccess()
        let reminder = try await store.reminder(id: taskId)
        if reminder.isCompleted {
            throw AppleTasksError.invalidInput("task \(taskId) is completed — nothing to retry")
        }
        let parsed = Tags.parse(reminder.title ?? "")
        guard let next = Self.requeueTags(parsed.tags) else {
            throw AppleTasksError.invalidInput(
                "task \(taskId) is still claimed [dispatched] — wait for it or cancel it first")
        }
        reminder.title = Tags.compose(tags: next.tags, title: parsed.title)
        try store.save(reminder)
        let ext = reminder.calendarItemExternalIdentifier
        if !next.removed.isEmpty { _ = NativeTags.remove(tags: next.removed, externalId: ext) }
        if next.addedAuto { _ = NativeTags.mirror(tags: ["auto"], externalId: ext) }

        // A human retry is a fresh start: older failures stop counting.
        AuditDB.shared.resetRetryBudget(taskId: taskId)
        AuditDB.shared.record(command: "dispatch-retry-requeue", taskId: taskId,
                              list: reminder.calendar?.title,
                              detail: parsed.title + (ledgerId.map { " (from #\($0))" } ?? ""))
        emit(Result(taskId: taskId, title: parsed.title, removedTags: next.removed,
                    addedAuto: next.addedAuto, fromLedgerId: ledgerId))
    }
}
