import CryptoKit
import EventKit
import Foundation

extension Dispatch {
    func writeBack(_ outcome: RunOutcome, store: Store, config: AgentsConfig) async -> DispatchReport {
        let spec = outcome.spec
        // Another process (`dispatch-cancel`, or a reap from a concurrent pass)
        // may have already killed this agent and finished the row. Its exit
        // then looks like a failure to us; keep their status (cancelled /
        // timeout) — they already wrote the tag and trailer — and don't page.
        if let current = AuditDB.shared.dispatchRow(id: spec.ledgerId), current.status != "running" {
            return DispatchReport(taskId: spec.taskId, title: spec.title, agent: spec.agentTag,
                                  cwd: spec.runCwd, action: "\(current.status) (finished by another process)",
                                  exitCode: outcome.exitCode.map(Int.init),
                                  runLog: spec.logPath, worktree: spec.worktree)
        }
        let trailerText = Self.trailer(ledgerId: spec.ledgerId, status: outcome.status,
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
        await Self.appendNotesTrailer(store: store, taskId: spec.taskId, trailer: trailerText)
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

        // Phase C verification (P3): record what the task looks like after
        // our trailer/notes write-back. An agent that exited 0 without
        // `apple-tasks complete` leaves our claim tag in place — shed it
        // so the task is not stranded, then re-fetch so the stored
        // fingerprint is the post-shed title + extra note.
        var reminder = try? await store.reminder(id: spec.taskId)
        let verification = Self.verification(
            isCompleted: reminder.map(\.isCompleted),
            tags: Tags.parse(reminder?.title ?? "").tags)
        if outcome.status == "succeeded", verification == "open-claimed" {
            _ = await Self.shedOwnDispatchedClaim(store: store, taskId: spec.taskId)
            await Self.appendNotesTrailer(
                store: store, taskId: spec.taskId,
                trailer: "[dispatch #\(spec.ledgerId)] agent exited 0 without completing the task — re-dispatch is blocked until the task changes")
            reminder = try? await store.reminder(id: spec.taskId)
        }
        AuditDB.shared.setVerification(
            id: spec.ledgerId,
            fingerprint: reminder.map(TaskFingerprint.of),
            modifiedAt: Dates.formatTimestamp(reminder?.lastModifiedDate),
            verification: verification)

        var action = outcome.spawnError.map { "spawn failed: \($0)" } ?? outcome.status
        if outcome.status == "succeeded", verification == "open-claimed" {
            action = "succeeded (open, claim shed)"
        }
        return DispatchReport(taskId: spec.taskId, title: spec.title, agent: spec.agentTag,
                              cwd: spec.runCwd, action: action,
                              exitCode: outcome.exitCode.map(Int.init),
                              runLog: spec.logPath, worktree: spec.worktree)
    }

    /// Post-run reminder state for the ledger. `isCompleted` nil means the
    /// reminder is gone (deleted) and counts as completed. A foreign Mac's
    /// `[dispatched:other]` is not ours, so that is `open-untagged`.
    static func verification(isCompleted: Bool?, tags: [String]) -> String {
        guard let isCompleted, !isCompleted else { return "completed" }
        if tags.contains(where: { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }) {
            return "open-claimed"
        }
        return "open-untagged"
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
    static func trailer(ledgerId: Int64, status: String, exitCode: Int32?,
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
    static func appendNotesTrailer(store: Store, taskId: String, trailer: String) async {
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

    /// Shed this Mac's [dispatched] claim (host-scoped or bare) without
    /// writing [failed]. Used by `dispatch-cancel`. Returns false if the
    /// reminder is gone or had no own claim tag.
    static func shedOwnDispatchedClaim(store: Store, taskId: String) async -> Bool {
        guard let current = try? await store.reminder(id: taskId) else { return false }
        var (tags, title) = Tags.parse(current.title ?? "")
        let hadClaim = tags.contains { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }
        tags.removeAll { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }
        current.title = Tags.compose(tags: tags, title: title)
        try? store.save(current)
        _ = NativeTags.remove(tags: [ClaimTags.dispatched, "dispatched"],
                              externalId: current.calendarItemExternalIdentifier)
        return hadClaim
    }
}
