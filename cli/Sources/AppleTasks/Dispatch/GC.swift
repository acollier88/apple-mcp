import EventKit
import Foundation

extension Dispatch {
    func reapAndCollect(config: AgentsConfig, store: Store) async -> [DispatchReport] {
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
}
