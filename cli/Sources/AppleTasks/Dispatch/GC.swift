import EventKit
import Foundation

extension Dispatch {
    func reapAndCollect(config: AgentsConfig, store: Store) async -> [DispatchReport] {
        var reports: [DispatchReport] = []

        // Reap first: rows orphaned in 'running' (dispatcher killed mid-run)
        // become 'timeout' and the task's [dispatched] tag becomes [failed],
        // so retry policy can pick them up. A still-alive agent is signalled
        // when the recorded pid still looks like this run.
        let iso = ISO8601DateFormatter()
        let deadCutoffDate = Date().addingTimeInterval(-10 * 60)
        for row in AuditDB.shared.dispatchRows(status: "running", limit: 1000) {
            guard let pid = row.pid else { continue }
            guard let started = iso.date(from: row.startedAt), started < deadCutoffDate else { continue }
            guard !AgentProcess.isAlive(Int32(pid)) else { continue }
            // A dead pid on a long run can also mean "agent just exited and its
            // dispatcher is mid write-back". That window is seconds and the run
            // log was just written; a dispatcher that died left an old log.
            if let logPath = row.runLogPath,
               let mtime = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) < 120 {
                continue
            }
            AuditDB.shared.finishDispatch(id: Int64(row.id), status: "timeout",
                                          exitCode: -1, summary: "dispatcher died")
            await markFailed(store: store, taskId: row.taskId)
            AuditDB.shared.record(command: "dispatch-reap", taskId: row.taskId,
                                  detail: "ledger #\(row.id) dispatcher died, pid \(pid) gone")
            reports.append(DispatchReport(taskId: row.taskId, title: "(ledger #\(row.id))",
                                          agent: row.agent, cwd: row.cwd,
                                          action: "reaped: dispatcher died, pid \(pid) gone",
                                          exitCode: nil, runLog: row.runLogPath, worktree: row.worktree))
        }
        let cutoff = iso.string(
            from: Date().addingTimeInterval(-TimeInterval(reapHours) * 3600))
        for stale in AuditDB.shared.reapStale(before: cutoff) {
            await markFailed(store: store, taskId: stale.taskId)
            var action = "reaped: running > \(reapHours)h, marked timeout"
            var detail = "ledger #\(stale.id) running since \(stale.startedAt)"
            if let pid = stale.pid,
               AgentProcess.looksLikeOurs(Int32(pid), ledgerId: Int64(stale.id),
                                          taskId: stale.taskId, agent: stale.agent) {
                let result = AgentProcess.terminate(Int32(pid))
                action = "reaped: killed pid \(pid) (\(result))"
                detail += "; killed pid \(pid) (\(result))"
            }
            AuditDB.shared.record(command: "dispatch-reap", taskId: stale.taskId, detail: detail)
            reports.append(DispatchReport(taskId: stale.taskId, title: "(ledger #\(stale.id))",
                                          agent: stale.agent, cwd: stale.cwd,
                                          action: action,
                                          exitCode: nil, runLog: stale.runLogPath, worktree: stale.worktree))
        }
        // Worktree GC: reclaim worktrees of finished runs. Merged succeeded
        // branches (and their worktrees) go immediately; failed/timeout/
        // cancelled worktrees are kept keepFailedWorktreeDays for debugging;
        // unmerged succeeded branches are deliverables. Their checkout can
        // be removed after pendingReviewWorktreeDays (default off); the
        // branch is kept and the row stays pending review.
        if !noGC {
            let keepDays = config.keepFailedWorktreeDays ?? 7
            let reviewDays = config.pendingReviewWorktreeDays ?? 0
            let keepCutoff = Date().addingTimeInterval(-TimeInterval(keepDays) * 86400)
            for row in AuditDB.shared.worktreeRows() {
                guard let wt = row.worktree, let repo = row.cwd, !repo.isEmpty else { continue }
                let branch = "agent/\(row.agent)-\(row.id)"
                guard FileManager.default.fileExists(atPath: wt) else {
                    // Age-out deletes the checkout and leaves this column so
                    // the branch stays on the pending-review list.
                    let branchExists = Self.runGit(
                        ["rev-parse", "--verify", "--quiet", branch], repo: repo) == 0
                    if Self.retainPendingWorktreeRecord(
                        status: row.status, reviewedAt: row.reviewedAt, branchExists: branchExists) {
                        continue
                    }
                    AuditDB.shared.clearWorktree(id: Int64(row.id))
                    continue
                }
                var action: String?
                switch row.status {
                case "succeeded":
                    if Self.runGit(["merge-base", "--is-ancestor", branch, "HEAD"], repo: repo) == 0 {
                        _ = Self.runGit(["worktree", "remove", "--force", wt], repo: repo)
                        _ = Self.runGit(["branch", "-d", branch], repo: repo)
                        AuditDB.shared.clearWorktree(id: Int64(row.id))
                        AuditDB.shared.markReviewed(id: Int64(row.id))
                        action = "gc: branch \(branch) merged, worktree removed"
                    } else if row.reviewedAt != nil {
                        // Accepted by opening a PR: drop the checkout, keep the branch.
                        _ = Self.runGit(["worktree", "remove", "--force", wt], repo: repo)
                        if !FileManager.default.fileExists(atPath: wt) {
                            AuditDB.shared.clearWorktree(id: Int64(row.id))
                            action = "gc: removed reviewed worktree, branch \(branch) kept"
                        }
                    } else if let aged = Self.ageOutPendingReviewWorktree(
                        worktree: wt, branch: branch, repo: repo,
                        finishedAt: row.finishedAt, keepDays: reviewDays) {
                        action = aged
                    } else {
                        action = "gc: kept, unmerged branch \(branch) pending"
                    }
                case "failed", "timeout", "cancelled":
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
            let scratchBase = AgentsConfig.url.deletingLastPathComponent()
                .appendingPathComponent("scratch")
            // Without the ledger every dir looks orphaned — skip rather than
            // delete a running agent's scratch space.
            if AuditDB.shared.isAvailable,
               let names = try? FileManager.default.contentsOfDirectory(atPath: scratchBase.path) {
                for name in names {
                    guard let id = Int64(name) else { continue }
                    let dir = scratchBase.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                          isDir.boolValue else { continue }
                    let row = AuditDB.shared.dispatchRow(id: id)
                    if let row {
                        guard row.status != "running" else { continue }
                        guard let finished = row.finishedAt,
                              let date = iso.date(from: finished), date < keepCutoff else { continue }
                    }
                    try? FileManager.default.removeItem(at: dir)
                    reports.append(DispatchReport(
                        taskId: row?.taskId ?? String(id),
                        title: row.map { "(ledger #\($0.id))" } ?? "(scratch #\(id))",
                        agent: row?.agent ?? "-",
                        cwd: dir.path,
                        action: "gc: removed scratch dir (>\(keepDays)d)",
                        exitCode: nil, runLog: row?.runLogPath, worktree: nil))
                }
            }
        }
        return reports
    }

    /// Keep the `worktree` column after the checkout directory is gone when
    /// the branch is still an unreviewed deliverable. Clearing it would drop
    /// the row from `pendingReviewRows` (that query requires the column).
    static func retainPendingWorktreeRecord(
        status: String, reviewedAt: String?, branchExists: Bool
    ) -> Bool {
        status == "succeeded" && reviewedAt == nil && branchExists
    }

    /// Remove a pending-review checkout once it is older than `keepDays`.
    /// `keepDays` < 1 (the default) does nothing. Never deletes the branch.
    /// Returns the GC action when the directory is gone, otherwise nil.
    static func ageOutPendingReviewWorktree(
        worktree: String,
        branch: String,
        repo: String,
        finishedAt: String?,
        keepDays: Int,
        now: Date = Date()
    ) -> String? {
        guard keepDays > 0 else { return nil }
        guard FileManager.default.fileExists(atPath: worktree) else { return nil }
        guard let finishedAt,
              let date = ISO8601DateFormatter().date(from: finishedAt),
              date < now.addingTimeInterval(-TimeInterval(keepDays) * 86400) else { return nil }
        _ = runGit(["worktree", "remove", "--force", worktree], repo: repo)
        guard !FileManager.default.fileExists(atPath: worktree) else { return nil }
        return "gc: removed pending-review worktree (>\(keepDays)d), branch \(branch) kept"
    }
}
