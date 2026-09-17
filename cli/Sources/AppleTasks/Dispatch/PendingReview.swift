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
}
