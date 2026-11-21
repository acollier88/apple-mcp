import CryptoKit
import Foundation

/// Detectors batch 1 (#57): queue health, lane health, cadence, dev hygiene.
/// Pure functions over snapshot fields; `DiagnosticsLive` gathers the inputs.
/// Proposable findings are `notice` severity, so doctor records them in the
/// proposals inbox and never turns them into heal tasks.
extension Diagnostics {
    // MARK: Inputs

    /// A task the dispatcher has left queued on consecutive live passes.
    struct WaitingTask: Codable, Equatable {
        var taskId: String
        var title: String
        var reason: String
        var passes: Int
        var since: String
    }

    /// Another Mac's `[dispatched:…]` / `[failed:…]` tag on an open task.
    struct ForeignClaim: Equatable {
        var taskId: String
        var title: String
        var tag: String
        var modified: Date
    }

    /// Ledger row, newest first.
    struct LaneRun: Equatable {
        var id: Int
        var agent: String
        var status: String
        var cwd: String?
        var verification: String?
    }

    /// One `dispatch` audit row: which task ran, under what title, when.
    struct DispatchedTitle: Equatable {
        var taskId: String
        var title: String
        var at: Date
    }

    struct StalePR: Equatable {
        var number: Int
        var title: String
        var url: String
        var ageDays: Int
    }

    struct RepoHygiene: Equatable {
        var name: String
        var mergedBranches: [String]
        /// Days since the newest uncommitted change; nil when the tree is clean.
        var dirtyDays: Int?
        /// Open PRs by the user with all checks green.
        var greenPRs: [StalePR]
    }

    struct PendingAge: Equatable {
        var ledgerId: Int
        var branch: String
        var repo: String
        var ageDays: Int
    }

    struct Batch1Thresholds: Equatable {
        var queueStuckPasses = 12
        var foreignClaimDays = 3
        var laneFailStreak = 3
        var repoUnverifiedStreak = 3
        var cadenceMinRuns = 3
        var stalePRDays = 7
        var dirtyCloneDays = 3
        var pendingReviewDays = 7
    }

    // MARK: Queue health

    /// The same skip reason on `minPasses` live passes in a row.
    static func queueStuck(_ waiting: [WaitingTask], minPasses: Int) -> [Finding] {
        waiting.filter { $0.passes >= minPasses }.map { task in
            Finding(
                signature: "queue-stuck:\(task.taskId)",
                system: "dispatch", severity: "yellow", kind: .needsHuman,
                summary: "\"\(redact(task.title, limit: 60))\" has waited \(task.passes) passes: \(task.reason)",
                evidence: "reason: \(task.reason)\nsince: \(task.since)",
                suggestedAction: "Clear what holds it (\(task.reason)), or remove [auto] if it should not run.")
        }
    }

    /// A claim from another Mac that has not moved in `days`: that Mac is
    /// probably gone, and the task will never run here while the tag stays.
    static func foreignClaims(_ claims: [ForeignClaim], now: Date, days: Int) -> [Finding] {
        claims.compactMap { claim in
            let age = Int(now.timeIntervalSince(claim.modified) / 86_400)
            guard age >= days else { return nil }
            return Finding(
                signature: "foreign-claim:\(claim.taskId)",
                system: "dispatch", severity: "yellow", kind: .needsHuman,
                summary: "\"\(redact(claim.title, limit: 60))\" is held by [\(claim.tag)], unchanged for \(age) days",
                evidence: "tag: \(claim.tag)",
                suggestedAction: "If that Mac is gone, remove [\(claim.tag)] from the task so this Mac can run it.")
        }
    }

    // MARK: Lane health

    /// `streak` or more failed/timed-out runs in a row, newest first, per lane.
    static func laneStreaks(_ runs: [LaneRun], streak: Int) -> [Finding] {
        var byLane: [String: [LaneRun]] = [:]
        for run in runs where run.status != "running" && run.status != "aborted" {
            byLane[run.agent, default: []].append(run)
        }
        return byLane.keys.sorted().compactMap { lane in
            let rows = byLane[lane] ?? []
            let failing = rows.prefix { $0.status == "failed" || $0.status == "timeout" }
            guard failing.count >= streak, let first = failing.last else { return nil }
            return Finding(
                signature: "lane-failing:\(lane)",
                system: "dispatch", severity: "yellow", kind: .healable,
                summary: "lane \(lane): \(failing.count) failed or timed-out runs in a row",
                // The streak's first row: stable while the streak lasts.
                evidence: "streak since ledger #\(first.id)",
                suggestedAction: "Read the run logs of lane \(lane)'s last failed runs (apple-tasks dispatches --status failed) "
                    + "and fix the lane's command, login or backend. Do not re-run the tasks themselves.")
        }
    }

    /// The last `streak` succeeded runs in one repo exited 0 without completing
    /// their task (`verification` open-claimed).
    static func repoUnverified(_ runs: [LaneRun], streak: Int) -> [Finding] {
        var byRepo: [String: [LaneRun]] = [:]
        for run in runs where run.status == "succeeded" {
            guard let cwd = run.cwd, !cwd.isEmpty, run.verification != nil else { continue }
            byRepo[cwd, default: []].append(run)
        }
        return byRepo.keys.sorted().compactMap { repo in
            let recent = (byRepo[repo] ?? []).prefix(streak)
            guard recent.count >= streak, recent.allSatisfy({ $0.verification == "open-claimed" }),
                  let first = recent.last else { return nil }
            let name = URL(fileURLWithPath: repo).lastPathComponent
            return Finding(
                signature: "repo-unverified:\(name)",
                system: "dispatch", severity: "notice", kind: .proposable,
                summary: "runs in \(name) keep exiting 0 without completing their task",
                evidence: "last \(streak) succeeded runs open-claimed since ledger #\(first.id)",
                suggestedAction: "Tighten the prompt template for \(name) so agents run `apple-tasks complete`, "
                    + "or add a completion step to the lane.")
        }
    }

    // MARK: Cadence

    /// The same title dispatched from `minRuns` or more different tasks at a
    /// steady interval (at least a day apart, spread under 25%).
    static func cadence(_ items: [DispatchedTitle], minRuns: Int) -> [Finding] {
        var groups: [String: [DispatchedTitle]] = [:]
        for item in items {
            let key = item.title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(item)
        }
        return groups.keys.sorted().compactMap { key in
            let rows = (groups[key] ?? []).sorted { $0.at < $1.at }
            // A recurring task keeps its id; repeats from new tasks are the signal.
            var seen: Set<String> = []
            let firsts = rows.filter { seen.insert($0.taskId).inserted }
            guard firsts.count >= minRuns else { return nil }
            let gaps = zip(firsts.dropFirst(), firsts).map { $0.at.timeIntervalSince($1.at) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            guard mean >= 20 * 3600 else { return nil }
            let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
            guard variance.squareRoot() <= 0.25 * mean else { return nil }
            let days = max(1, Int((mean / 86_400).rounded()))
            let title = firsts.last?.title ?? key
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return Finding(
                signature: "cadence:\(hash.prefix(12))",
                system: "tasks", severity: "notice", kind: .proposable,
                summary: "\"\(redact(title, limit: 60))\" was created and dispatched \(firsts.count) times, "
                    + "about every \(days) day\(days == 1 ? "" : "s"): make it a recurring task",
                evidence: "\(firsts.count) tasks, interval ~\(days)d",
                suggestedAction: "Replace the copies with one task that repeats every \(days) day\(days == 1 ? "" : "s") "
                    + "(apple-tasks update <id> --recurrence …).")
        }
    }

    // MARK: Dev hygiene

    static func devHygiene(repos: [RepoHygiene], pending: [PendingAge], limits: Batch1Thresholds) -> [Finding] {
        var out: [Finding] = []
        for repo in repos.sorted(by: { $0.name < $1.name }) {
            for pr in repo.greenPRs where pr.ageDays >= limits.stalePRDays {
                out.append(Finding(
                    signature: "stale-pr:\(repo.name)#\(pr.number)",
                    system: "dev", severity: "notice", kind: .proposable,
                    summary: "\(repo.name) PR #\(pr.number) \"\(redact(pr.title, limit: 60))\" has been open "
                        + "\(pr.ageDays) days with green CI",
                    evidence: "\(pr.url) green",
                    suggestedAction: "Merge or close \(pr.url)."))
            }
            if !repo.mergedBranches.isEmpty {
                let names = repo.mergedBranches.sorted()
                out.append(Finding(
                    signature: "merged-branches:\(repo.name)",
                    system: "dev", severity: "notice", kind: .proposable,
                    summary: "\(names.count) local branch\(names.count == 1 ? "" : "es") in \(repo.name) already merged",
                    evidence: names.joined(separator: "\n"),
                    suggestedAction: "Delete them in \(repo.name): git branch -d " + names.prefix(10).joined(separator: " ")))
            }
            if let days = repo.dirtyDays, days >= limits.dirtyCloneDays {
                out.append(Finding(
                    signature: "dirty-clone:\(repo.name)",
                    system: "dev", severity: "notice", kind: .proposable,
                    summary: "\(repo.name) has uncommitted changes untouched for \(days) days",
                    evidence: "dirty, newest change \(days)d old",
                    suggestedAction: "Commit, stash or discard the work in \(repo.name) so it is not lost or shipped by accident."))
            }
        }
        for item in pending where item.ageDays >= limits.pendingReviewDays {
            let name = URL(fileURLWithPath: item.repo).lastPathComponent
            out.append(Finding(
                signature: "pending-review:\(item.ledgerId)",
                system: "dev", severity: "notice", kind: .proposable,
                summary: "agent branch \(item.branch) in \(name) has waited \(item.ageDays) days for review",
                evidence: "\(item.branch) pending",
                suggestedAction: "Review it: apple-tasks dispatch-accept \(item.ledgerId) or dispatch-discard \(item.ledgerId)."))
        }
        return out
    }

    // MARK: Waiting record (written by live dispatch passes)

    static let waitingKey = "queue.waiting"

    /// Skips that leave a task queued. Daily caps are reported by `limits`.
    static func waitingReason(_ action: String) -> String? {
        guard action.contains("stays queued") else { return nil }
        let reason = action.components(separatedBy: " — ").first ?? action
        if reason.hasPrefix("gated: daily") { return nil }
        return reason
    }

    /// Next record: same reason → passes + 1; new reason → restart; tasks not
    /// waiting this pass drop out.
    static func nextWaiting(previous: [WaitingTask], reports: [(taskId: String, title: String, action: String)],
                            now: String) -> [WaitingTask] {
        let byId = Dictionary(previous.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [WaitingTask] = []
        var seen: Set<String> = []
        for report in reports {
            guard !report.taskId.isEmpty, let reason = waitingReason(report.action),
                  seen.insert(report.taskId).inserted else { continue }
            if let old = byId[report.taskId], old.reason == reason {
                out.append(WaitingTask(taskId: report.taskId, title: report.title, reason: reason,
                                       passes: old.passes + 1, since: old.since))
            } else {
                out.append(WaitingTask(taskId: report.taskId, title: report.title, reason: reason,
                                       passes: 1, since: now))
            }
        }
        return out
    }

    static func readWaiting(db: AuditDB = .shared) -> [WaitingTask] {
        guard let raw = db.getState(waitingKey),
              let rows = try? JSONDecoder().decode([WaitingTask].self, from: Data(raw.utf8)) else { return [] }
        return rows
    }

    static func recordWaiting(reports: [Dispatch.DispatchReport], db: AuditDB = .shared, now: Date = Date()) {
        let next = nextWaiting(
            previous: readWaiting(db: db),
            reports: reports.map { ($0.taskId, $0.title, $0.action) },
            now: ISO8601DateFormatter().string(from: now))
        let data = (try? JSONEncoder().encode(next)) ?? Data("[]".utf8)
        _ = db.setState(waitingKey, String(decoding: data, as: UTF8.self))
    }
}
