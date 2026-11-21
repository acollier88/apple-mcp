import EventKit
import Foundation

/// Live inputs for detectors batch 1 (#57). Local reads plus `git` and, when
/// installed, `gh` (one `pr list` per configured workdir, 15s cap each).
extension DiagnosticsLive {
    static func batch1(into snap: inout Diagnostics.Snapshot, config: AgentsConfig?,
                       settings: AgentsConfig.DetectorSettings?, now: Date) async {
        if Diagnostics.enabled(Diagnostics.ID.queueHealth, settings) {
            snap.waiting = Diagnostics.readWaiting()
            snap.foreignClaims = await foreignClaims()
        }
        if Diagnostics.enabled(Diagnostics.ID.laneHealth, settings) {
            snap.laneRuns = AuditDB.shared.dispatchRows(status: nil, limit: 300).map {
                Diagnostics.LaneRun(id: $0.id, agent: $0.agent, status: $0.status,
                                    cwd: $0.cwd, verification: $0.verification)
            }
        }
        if Diagnostics.enabled(Diagnostics.ID.cadence, settings) {
            snap.dispatched = dispatchedTitles(now: now)
        }
        if Diagnostics.enabled(Diagnostics.ID.devHygiene, settings) {
            snap.repos = repoHygiene(workdirs: config?.workdirs ?? [:], now: now)
            snap.pending = PendingReview.items().compactMap { item in
                guard let repo = item.cwd, let finished = item.finishedAt,
                      let date = ISO8601DateFormatter().date(from: finished) else { return nil }
                return Diagnostics.PendingAge(ledgerId: item.id, branch: item.branch, repo: repo,
                                              ageDays: Int(now.timeIntervalSince(date) / 86_400))
            }
        }
    }

    private static func foreignClaims() async -> [Diagnostics.ForeignClaim] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = Store()
        guard (try? await store.requestAccess()) != nil else { return [] }
        var out: [Diagnostics.ForeignClaim] = []
        for reminder in await store.reminders(in: nil) where !reminder.isCompleted {
            let parsed = Tags.parse(reminder.title ?? "")
            guard let tag = parsed.tags.first(where: {
                (ClaimTags.isDispatched($0) || ClaimTags.isFailed($0)) && !ClaimTags.isOwn($0)
            }), let modified = reminder.lastModifiedDate else { continue }
            out.append(Diagnostics.ForeignClaim(
                taskId: reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier,
                title: parsed.title, tag: tag, modified: modified))
            if out.count >= 50 { break }
        }
        return out
    }

    /// `dispatch` audit rows of the last 90 days. Detail is "<agent>: <title>"
    /// with an optional " (attempt n)".
    static func dispatchedTitles(now: Date) -> [Diagnostics.DispatchedTitle] {
        let iso = ISO8601DateFormatter()
        let since = iso.string(from: now.addingTimeInterval(-90 * 86_400))
        return AuditDB.shared.auditRows(since: since, taskId: nil, caller: nil, limit: 5000).compactMap { row in
            guard row.command == "dispatch", let taskId = row.taskId, let detail = row.detail,
                  let at = iso.date(from: row.ts) else { return nil }
            return Diagnostics.DispatchedTitle(taskId: taskId, title: dispatchTitle(detail), at: at)
        }
    }

    static func dispatchTitle(_ detail: String) -> String {
        var title = detail
        if let colon = title.range(of: ": ") { title = String(title[colon.upperBound...]) }
        if let attempt = title.range(of: #" \(attempt \d+\)$"#, options: .regularExpression) {
            title.removeSubrange(attempt)
        }
        return title
    }

    private static func repoHygiene(workdirs: [String: String], now: Date) -> [Diagnostics.RepoHygiene] {
        let paths = Set(workdirs.values.map { NSString(string: $0).expandingTildeInPath })
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return paths.sorted().compactMap { path in
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
            else { return nil }
            return Diagnostics.RepoHygiene(
                name: URL(fileURLWithPath: path).lastPathComponent,
                mergedBranches: mergedBranches(repo: path),
                dirtyDays: dirtyDays(repo: path, now: now),
                greenPRs: gh.map { greenPRs(gh: $0, repo: path, now: now) } ?? [])
        }
    }

    private static func git(_ repo: String, _ args: [String]) -> String? {
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"), ["-c", "core.fsmonitor=false", "-C", repo] + args, timeout: 10),
            result.status == 0, !result.timedOut else { return nil }
        return result.stdoutString
    }

    /// Local branches merged into the default branch, other than the default,
    /// the checked-out one, and `agent/*` (dispatch GC owns those).
    static func mergedBranches(repo: String) -> [String] {
        let remoteHead = git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = remoteHead.map { String($0.split(separator: "/").dropFirst().joined(separator: "/")) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        let target = git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"]) != nil
            ? base : (remoteHead ?? base)
        guard let out = git(repo, ["for-each-ref", "--format=%(refname:short)", "--merged", target, "refs/heads"]) else {
            return []
        }
        let current = git(repo, ["branch", "--show-current"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return filterMerged(out.split(separator: "\n").map(String.init), base: base, current: current)
    }

    static func filterMerged(_ names: [String], base: String, current: String?) -> [String] {
        names.filter { name in
            !name.isEmpty && name != base && name != current && !name.hasPrefix("agent/")
                && !["main", "master", "develop"].contains(name)
        }
    }

    /// Days since the most recently modified uncommitted path; nil when clean.
    private static func dirtyDays(repo: String, now: Date) -> Int? {
        guard let status = git(repo, ["status", "--porcelain"]), !status.isEmpty else { return nil }
        var newest: Date?
        for line in status.split(separator: "\n").prefix(200) where line.count > 3 {
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let full = URL(fileURLWithPath: repo).appendingPathComponent(path).path
            if let date = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date,
               newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        guard let newest else { return 0 }
        return max(0, Int(now.timeIntervalSince(newest) / 86_400))
    }

    private struct PR: Decodable {
        struct Check: Decodable {
            let conclusion: String?
            let state: String?
        }
        let number: Int
        let title: String
        let url: String
        let createdAt: String
        let statusCheckRollup: [Check]?
    }

    private static func greenPRs(gh: String, repo: String, now: Date) -> [Diagnostics.StalePR] {
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: gh),
            ["pr", "list", "--author", "@me", "--state", "open", "--limit", "30",
             "--json", "number,title,url,createdAt,statusCheckRollup"],
            timeout: 15, directory: URL(fileURLWithPath: repo)),
            result.status == 0, !result.timedOut,
            let prs = try? JSONDecoder().decode([PR].self, from: result.stdout) else { return [] }
        let iso = ISO8601DateFormatter()
        return prs.compactMap { pr in
            guard let checks = pr.statusCheckRollup, isGreen(checks.map { $0.conclusion ?? $0.state ?? "" }),
                  let created = iso.date(from: pr.createdAt) else { return nil }
            return Diagnostics.StalePR(number: pr.number, title: pr.title, url: pr.url,
                                       ageDays: Int(now.timeIntervalSince(created) / 86_400))
        }
    }

    /// Every check finished and none failed.
    static func isGreen(_ outcomes: [String]) -> Bool {
        !outcomes.isEmpty && outcomes.allSatisfy { ["SUCCESS", "SKIPPED", "NEUTRAL"].contains($0.uppercased()) }
    }
}
