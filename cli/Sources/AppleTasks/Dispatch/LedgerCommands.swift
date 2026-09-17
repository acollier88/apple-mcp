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

        var processNote = "not found"
        if let pid = row.pid,
           AgentProcess.looksLikeOurs(Int32(pid), ledgerId: Int64(row.id),
                                      taskId: row.taskId, agent: row.agent) {
            processNote = AgentProcess.terminate(Int32(pid))
        }

        AuditDB.shared.finishDispatch(
            id: ledgerId, status: "cancelled", exitCode: -1,
            summary: "cancelled by \(AuditDB.caller)")

        var tagShed = false
        var title = row.command
        var list: String?
        do {
            let store = Store()
            try await store.requestAccess()
            tagShed = await Dispatch.shedOwnDispatchedClaim(store: store, taskId: row.taskId)
            if let reminder = try? await store.reminder(id: row.taskId) {
                let parsed = Tags.parse(reminder.title ?? "")
                title = parsed.title.isEmpty ? (reminder.title ?? row.command) : parsed.title
                list = reminder.calendar?.title
            }
            let trailerText = Dispatch.trailer(
                ledgerId: ledgerId, status: "cancelled", exitCode: -1,
                branch: nil, repo: row.cwd, logPath: row.runLogPath, seat: nil)
            await Dispatch.appendNotesTrailer(store: store, taskId: row.taskId, trailer: trailerText)
        } catch {
            // Reminder gone or no access: the ledger row is still cancelled.
        }

        AuditDB.shared.record(command: "dispatch-cancel", taskId: row.taskId,
                              list: list, detail: "\(row.agent): \(title)", result: "ok")
        emit(Result(id: row.id, taskId: row.taskId, agent: row.agent,
                    status: "cancelled", process: processNote, tagShed: tagShed))
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
