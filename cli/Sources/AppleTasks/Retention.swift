import Foundation

/// `retention` in agents.json (#70). Each value is days; 0 keeps forever.
struct RetentionConfig: Codable, Equatable {
    /// Run log + prompt file of a succeeded/cancelled run (default 30).
    var runLogDays: Int?
    /// Run log + prompt file of a failed/timeout/aborted run (default 90).
    var failedRunLogDays: Int?
    /// Clear agent summaries, audit details and answered approval questions
    /// older than this; the rows stay (default 180).
    var ledgerTextDays: Int?
}

/// Pruning run in the GC step of every live (non-dry-run) dispatch pass.
enum Retention {
    struct Policy: Equatable {
        var runLogDays: Int
        var failedRunLogDays: Int
        var ledgerTextDays: Int

        static let defaults = Policy(runLogDays: 30, failedRunLogDays: 90, ledgerTextDays: 180)

        init(runLogDays: Int, failedRunLogDays: Int, ledgerTextDays: Int) {
            self.runLogDays = runLogDays
            self.failedRunLogDays = failedRunLogDays
            self.ledgerTextDays = ledgerTextDays
        }

        init(_ config: RetentionConfig?) {
            let d = Policy.defaults
            runLogDays = max(0, config?.runLogDays ?? d.runLogDays)
            failedRunLogDays = max(0, config?.failedRunLogDays ?? d.failedRunLogDays)
            ledgerTextDays = max(0, config?.ledgerTextDays ?? d.ledgerTextDays)
        }
    }

    static let succeededStatuses = ["succeeded", "cancelled"]
    static let failedStatuses = ["failed", "timeout", "aborted"]
    /// VACUUM at most this often.
    static let compactEvery: TimeInterval = 86_400
    static let compactStateKey = "retention.compacted"

    struct Result: Codable, Equatable {
        var runLogsRemoved = 0
        var promptFilesRemoved = 0
        var textCleared = 0
        var compacted = false
        var skipped: [String] = []

        var isEmpty: Bool {
            runLogsRemoved == 0 && promptFilesRemoved == 0 && textCleared == 0 && !compacted && skipped.isEmpty
        }
    }

    /// The prompt copy written beside `<id>.log` (`Plan.swift`).
    static func promptPath(forLog log: String) -> String? {
        guard log.hasSuffix(".log") else { return nil }
        return String(log.dropLast(".log".count)) + ".prompt"
    }

    /// Only files inside the runs directory are ever deleted.
    static func isInside(_ path: String, directory: URL) -> Bool {
        let dir = directory.standardizedFileURL.path
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        return file.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    static func cutoff(days: Int, now: Date) -> String? {
        guard days > 0 else { return nil }
        return ISO8601DateFormatter().string(from: now.addingTimeInterval(-TimeInterval(days) * 86_400))
    }

    static func prune(policy: Policy, runs: URL, db: AuditDB = .shared, now: Date = Date(),
                      fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        for (statuses, days) in [(succeededStatuses, policy.runLogDays),
                                 (failedStatuses, policy.failedRunLogDays)] {
            guard let before = cutoff(days: days, now: now) else { continue }
            for row in db.runLogsToPrune(statuses: statuses, finishedBefore: before) {
                guard let log = row.runLogPath else { continue }
                guard isInside(log, directory: runs) else {
                    result.skipped.append("#\(row.id): run log outside \(runs.path)")
                    continue
                }
                var removedAll = true
                for (path, isLog) in [(log, true), (promptPath(forLog: log), false)] {
                    guard let path, fm.fileExists(atPath: path) else { continue }
                    if (try? fm.removeItem(atPath: path)) != nil {
                        if isLog { result.runLogsRemoved += 1 } else { result.promptFilesRemoved += 1 }
                    } else {
                        removedAll = false
                        result.skipped.append("#\(row.id): could not remove \(URL(fileURLWithPath: path).lastPathComponent)")
                    }
                }
                if removedAll { db.clearRunLogPath(id: Int64(row.id)) }
            }
        }
        if let before = cutoff(days: policy.ledgerTextDays, now: now) {
            if let cleared = db.scrubText(before: before) {
                result.textCleared = cleared
            } else {
                result.skipped.append("ledger text: update failed")
            }
        }
        let iso = ISO8601DateFormatter()
        let last = db.getState(compactStateKey).flatMap { iso.date(from: $0) }
        if last.map({ now.timeIntervalSince($0) >= compactEvery }) ?? true {
            result.compacted = db.compact()
            if result.compacted { _ = db.setState(compactStateKey, iso.string(from: now)) }
        }
        return result
    }

    struct Status: Codable, Equatable {
        var runLogDays: Int
        var failedRunLogDays: Int
        var ledgerTextDays: Int
        var runsFiles: Int
        var runsBytes: Int64
        var ledgerBytes: Int64
        var walBytes: Int64
        var oldestRetainedRun: String?
        var lastCompacted: String?
    }

    static func status(policy: Policy, runs: URL, ledger: URL, db: AuditDB = .shared,
                       fileManager fm: FileManager = .default) -> Status {
        var files = 0
        var bytes: Int64 = 0
        for name in (try? fm.contentsOfDirectory(atPath: runs.path)) ?? [] {
            let size = (try? fm.attributesOfItem(atPath: runs.appendingPathComponent(name).path))?[.size] as? NSNumber
            files += 1
            bytes += size?.int64Value ?? 0
        }
        func size(_ path: String) -> Int64 {
            ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return Status(
            runLogDays: policy.runLogDays, failedRunLogDays: policy.failedRunLogDays,
            ledgerTextDays: policy.ledgerTextDays, runsFiles: files, runsBytes: bytes,
            ledgerBytes: size(ledger.path), walBytes: size(ledger.path + "-wal"),
            oldestRetainedRun: db.oldestRetainedRunLog(), lastCompacted: db.getState(compactStateKey))
    }
}
