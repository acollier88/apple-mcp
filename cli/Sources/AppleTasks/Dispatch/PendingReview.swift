import Foundation

struct PendingReviewItem: Codable {
    let id: Int
    let taskId: String
    let agent: String
    let command: String
    let cwd: String?
    let startedAt: String
    let finishedAt: String?
    let status: String
    let exitCode: Int?
    let runLogPath: String?
    let worktree: String?
    let summary: String?
    let branch: String
    let commitsAhead: Int
    let commits: [String]
    /// How long the run has been waiting, from `finishedAt` ("3d old",
    /// "just now", "age unknown"). Computed when the item is built.
    let age: String

    init(row: AuditDB.DispatchRow, branch: String, commitsAhead: Int, commits: [String]) {
        self.id = row.id
        self.taskId = row.taskId
        self.agent = row.agent
        self.command = row.command
        self.cwd = row.cwd
        self.startedAt = row.startedAt
        self.finishedAt = row.finishedAt
        self.status = row.status
        self.exitCode = row.exitCode
        self.runLogPath = row.runLogPath
        self.worktree = row.worktree
        self.summary = row.summary
        self.branch = branch
        self.commitsAhead = commitsAhead
        self.commits = commits
        self.age = Self.ageLabel(finishedAt: row.finishedAt)
    }

    /// Compact age for digest lines and the review notification.
    /// `now` is injectable so tests can pin a clock.
    static func ageLabel(finishedAt: String?, now: Date = Date()) -> String {
        guard let finishedAt,
              let date = ISO8601DateFormatter().date(from: finishedAt) else {
            return "age unknown"
        }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m old" }
        if seconds < 86_400 { return "\(seconds / 3600)h old" }
        return "\(seconds / 86_400)d old"
    }
}

enum PendingReview {
    /// pendingReviewRows() filtered to branches that still exist AND are unmerged.
    /// Side effects: a row whose branch is gone or fully merged is markReviewed()
    /// (and clearWorktree if the worktree dir is gone) so it stops showing up.
    static func items(db: AuditDB = .shared, limit: Int = 200) -> [PendingReviewItem] {
        var items: [PendingReviewItem] = []
        for row in db.pendingReviewRows(limit: limit) {
            let branch = row.branch ?? "agent/\(row.agent)-\(row.id)"
            guard let repo = row.cwd, !repo.isEmpty, isGitRepo(repo) else {
                markSettled(row, db: db)
                continue
            }
            guard branchExists(branch, repo: repo) else {
                markSettled(row, db: db)
                continue
            }
            guard let ahead = commitsAhead(branch, repo: repo), ahead > 0 else {
                markSettled(row, db: db)
                continue
            }
            items.append(PendingReviewItem(
                row: row, branch: branch, commitsAhead: ahead,
                commits: commitLines(branch, repo: repo)))
        }
        return items
    }

    private static func markSettled(_ row: AuditDB.DispatchRow, db: AuditDB) {
        db.markReviewed(id: Int64(row.id))
        if let wt = row.worktree, !FileManager.default.fileExists(atPath: wt) {
            db.clearWorktree(id: Int64(row.id))
        }
    }

    private static func isGitRepo(_ repo: String) -> Bool {
        Dispatch.runGit(["rev-parse", "--git-dir"], repo: repo) == 0
    }

    private static func branchExists(_ branch: String, repo: String) -> Bool {
        Dispatch.runGit(["rev-parse", "--verify", "--quiet", branch], repo: repo) == 0
    }

    private static func commitsAhead(_ branch: String, repo: String) -> Int? {
        guard let raw = Dispatch.gitOutput(
            ["rev-list", "--count", branch, "--not", "HEAD"], repo: repo)
        else { return nil }
        return Int(raw)
    }

    private static func commitLines(_ branch: String, repo: String) -> [String] {
        guard let raw = Dispatch.gitOutput(
            ["log", "--oneline", "-n", "3", "HEAD..\(branch)"], repo: repo),
              !raw.isEmpty
        else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: - notification

    /// Ledger state key. The value is `notifySignature` of the set we last
    /// considered, including "" once an empty backlog has been seen.
    static let notifyStateKey = "pendingReview.notified"

    struct NotifyPlan: Equatable {
        let shouldNotify: Bool
        let signature: String
        let title: String
        let body: String
    }

    /// Same ledger id + branch with the same commits stays quiet. A new row,
    /// a removed row, or a new commit changes the signature and notifies
    /// again. Age is not part of the signature — it moves every hour and
    /// would re-page on every pass.
    static func notifySignature(_ items: [PendingReviewItem]) -> String {
        items.map { "\($0.id)\t\($0.branch)\t\($0.commitsAhead)\t\($0.commits.first ?? "")" }
            .sorted()
            .joined(separator: "\n")
    }

    static func notifyPlan(items: [PendingReviewItem], previousSignature: String?) -> NotifyPlan {
        let signature = notifySignature(items)
        let title = items.count == 1
            ? "1 branch awaiting review"
            : "\(items.count) branches awaiting review"
        let shown = items.prefix(12).map { Digest.pendingReviewLine($0) }
        var body = shown.joined(separator: "\n")
        if items.count > shown.count {
            body += "\n+\(items.count - shown.count) more"
        }
        if body.count > 1500 {
            body = String(body.prefix(1500))
        }
        let changed = signature != (previousSignature ?? "")
        return NotifyPlan(shouldNotify: !items.isEmpty && changed,
                          signature: signature, title: title, body: body)
    }

    /// Banner + ntfy (best-effort when no topic is configured). Records the
    /// signature even when the backlog is empty, so the next new branch
    /// notifies once and an unchanged set does not page on every pass.
    @discardableResult
    static func notifyIfChanged(items: [PendingReviewItem], db: AuditDB) async -> Bool {
        let previous = db.getState(notifyStateKey)
        let plan = notifyPlan(items: items, previousSignature: previous)
        guard plan.signature != previous else { return false }
        if plan.shouldNotify {
            Notifier.banner(title: plan.title, body: plan.body)
            await Notifier.push(title: plan.title, body: plan.body)
        }
        db.setState(notifyStateKey, plan.signature)
        return plan.shouldNotify
    }
}
