import CryptoKit
import EventKit
import Foundation

extension Dispatch {
    func writeBack(_ outcome: RunOutcome, store: Store, config: AgentsConfig) async -> DispatchReport {
        let spec = outcome.spec
        let trailerText = trailer(ledgerId: spec.ledgerId, status: outcome.status,
                                  exitCode: outcome.exitCode, branch: spec.branch,
                                  repo: spec.repo, logPath: spec.logPath,
                                  seat: outcome.seat)
        AuditDB.shared.finishDispatch(id: spec.ledgerId,
                                      status: outcome.status == "succeeded" ? "succeeded" : outcome.status == "timeout" ? "timeout" : "failed",
                                      exitCode: outcome.exitCode ?? -1,
                                      summary: trailerText.components(separatedBy: "\n").first)
        if outcome.status != "succeeded" {
            await markFailed(store: store, taskId: spec.taskId)
        }
        await appendNotesTrailer(store: store, taskId: spec.taskId, trailer: trailerText)
        let notifyOn = config.notifyOn ?? "failure"
        let summaryLine = trailerText.components(separatedBy: "\n").first ?? outcome.status
        if notifyOn == "all" || (notifyOn == "failure" && outcome.status != "succeeded") {
            Notifier.banner(title: spec.title, body: summaryLine)
        }
        // Failures always reach the phone when ntfy is configured —
        // the banner is useless if you're not at the Mac.
        if outcome.status != "succeeded" {
            await Notifier.push(title: "agent \(outcome.status): \(spec.title)", body: summaryLine)
        }
        let action = outcome.spawnError.map { "spawn failed: \($0)" } ?? outcome.status
        return DispatchReport(taskId: spec.taskId, title: spec.title, agent: spec.agentTag,
                              cwd: spec.runCwd, action: action,
                              exitCode: outcome.exitCode.map(Int.init),
                              runLog: spec.logPath, worktree: spec.worktree)
    }

    /// Emit the pass report, or `[]` under `--quiet` when this pass only
    /// repeated the same GC/skip noise as the previous one.
    func emitReports(_ reports: [DispatchReport]) {
        let key = reports.map { $0.action + $0.taskId }.sorted().joined()
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let noiseOnly = reports.allSatisfy { report in
            let action = report.action
            if action.hasPrefix("skipped: ledger") { return false }
            return action.hasPrefix("gc:")
                || action.hasPrefix("skipped:")
                || action.hasPrefix("gated:")
                || action.hasPrefix("scheduled:")
        }
        if quiet, noiseOnly, AuditDB.shared.getState("dispatch.lastReportHash") == hash {
            emit([DispatchReport]())
            return
        }
        AuditDB.shared.setState("dispatch.lastReportHash", hash)
        emit(reports)
    }

    /// One-line run outcome for the ledger, plus (for succeeded worktree
    /// runs) up to 3 commit oneliners showing what the branch produced.
    private func trailer(ledgerId: Int64, status: String, exitCode: Int32?,
                         branch: String?, repo: String?, logPath: String?,
                         seat: AgentSeat.Info?) -> String {
        var line = "[dispatch #\(ledgerId)] \(status)"
        if let exitCode { line += " exit=\(exitCode)" }
        if let seat { line += " \(seat.summary)" }
        if let branch { line += " branch=\(branch)" }
        if let logPath { line += " log=\(logPath)" }
        if status == "succeeded", let branch, let repo,
           let commits = Self.gitOutput(["log", "--oneline", "-3", branch, "--not", "HEAD"], repo: repo),
           !commits.isEmpty {
            line += "\n" + commits
        }
        return line
    }

    /// Append the run trailer to the task notes, re-fetching first because
    /// the agent may have edited the task meanwhile. Best-effort.
    private func appendNotesTrailer(store: Store, taskId: String, trailer: String) async {
        guard let current = try? await store.reminder(id: taskId) else { return }
        let existing = current.notes.map { $0.isEmpty ? "" : $0 + "\n\n" } ?? ""
        current.notes = existing + trailer
        try? store.save(current)
    }

    /// Swap this Mac's [dispatched] claim for its [failed] tag, re-fetching
    /// first because the agent may have edited it meanwhile. Another Mac's
    /// claim tags are never touched (IDEAS #13).
    func markFailed(store: Store, taskId: String) async {
        guard let current = try? await store.reminder(id: taskId) else { return }
        var (tags, title) = Tags.parse(current.title ?? "")
        tags.removeAll { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }
        if !tags.contains(where: { ClaimTags.isFailed($0) && ClaimTags.isOwn($0) }) {
            tags.append(ClaimTags.failed)
        }
        current.title = Tags.compose(tags: tags, title: title)
        try? store.save(current)
        // Native side follows the title: drop this Mac's #dispatched chip,
        // paint #failed once.
        _ = NativeTags.remove(tags: [ClaimTags.dispatched, "dispatched"], externalId: current.calendarItemExternalIdentifier)
        _ = NativeTags.mirror(tags: [ClaimTags.failed], externalId: current.calendarItemExternalIdentifier)
    }
}
