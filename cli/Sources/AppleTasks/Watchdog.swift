import ArgumentParser
import Foundation

/// A second, tiny checker for the dispatcher (#56). It reads two heartbeat
/// files and the ledger, and pushes a notification when something changes.
/// It does not touch EventKit or start an agent.
///
/// - The dispatcher writes `heartbeats/dispatcher.json` at pass start and end.
/// - `apple-tasks watchdog` (its own LaunchAgent, `make install-watchdog`)
///   writes `heartbeats/watchdog.json` and alerts on a pass running past the
///   dispatcher's own cap, no finished pass for a while, or running rows
///   whose agent pid is gone.
/// - Dead-man's switch: each dispatch pass checks the watchdog's heartbeat
///   and pushes once if an installed watchdog has stopped checking in.
enum Watchdog {
    /// No finished pass for this long is an alert (launchd interval is 5 min).
    static let maxSilenceSeconds: TimeInterval = 20 * 60
    /// The watchdog runs every 3 minutes; silence past this means it died.
    static let watchdogSilenceSeconds: TimeInterval = 20 * 60
    /// Slack on top of the dispatcher's own pass cap before calling it hung.
    static let passGraceSeconds: TimeInterval = 10 * 60
    static let label = "com.apple-tasks.watchdog"

    struct Beat: Codable, Equatable {
        var role: String
        var pid: Int32
        var started: String
        var finished: String?
    }

    enum Notice: Equatable {
        case passTooLong(Int)
        case noRecentPass(Int)
        case deadRunning(Int)
        case watchdogSilent(Int)
    }

    static func directory(override: String? = ProcessInfo.processInfo.environment["APPLE_TASKS_CONFIG_DIR"]) -> URL {
        let base: URL
        if let override, !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/apple-tasks", isDirectory: true)
        }
        return base.appendingPathComponent("heartbeats", isDirectory: true)
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func date(_ stamp: String) -> Date? { ISO8601DateFormatter().date(from: stamp) }

    static func write(_ beat: Beat, to directory: URL) throws {
        _ = ConfigPermissions.ensurePrivateDirectory(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(beat)
        try data.write(to: directory.appendingPathComponent("\(beat.role).json"), options: .atomic)
    }

    static func read(role: String, from directory: URL) -> Beat? {
        let url = directory.appendingPathComponent("\(role).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Beat.self, from: data)
    }

    static func markDispatcher(start: Date, finish: Date?, directory: URL = directory()) {
        let beat = Beat(role: "dispatcher", pid: ProcessInfo.processInfo.processIdentifier,
                        started: stamp(start), finished: finish.map(stamp))
        try? write(beat, to: directory)
    }

    /// A pass may legitimately run until the dispatcher's own cap
    /// (`maxPassMinutes`, default 8h, #75), so alert only past that.
    static func maxPassSeconds(config: AgentsConfig?) -> TimeInterval {
        let minutes = config?.resolvedMaxPassMinutes ?? AgentsConfig.defaultMaxPassMinutes
        return TimeInterval(minutes) * 60 + passGraceSeconds
    }

    static func watchdogInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path)
    }

    static func notices(dispatcher: Beat?, watchdog: Beat?, now: Date,
                        deadRunning: Int,
                        maxPass: TimeInterval,
                        maxSilence: TimeInterval = maxSilenceSeconds,
                        watchdogInstalled: Bool = true) -> [Notice] {
        var found: [Notice] = []
        if let dispatcher, let started = date(dispatcher.started) {
            if dispatcher.finished == nil {
                let elapsed = now.timeIntervalSince(started)
                if elapsed > maxPass { found.append(.passTooLong(Int(elapsed))) }
            } else if let finished = dispatcher.finished.flatMap(date) {
                let quiet = now.timeIntervalSince(finished)
                if quiet > maxSilence { found.append(.noRecentPass(Int(quiet))) }
            }
        }
        if deadRunning > 0 { found.append(.deadRunning(deadRunning)) }
        if watchdogInstalled, let watchdog,
           let last = watchdog.finished.flatMap(date) ?? date(watchdog.started) {
            let quiet = now.timeIntervalSince(last)
            if quiet > watchdogSilenceSeconds { found.append(.watchdogSilent(Int(quiet))) }
        }
        return found
    }

    static func summary(_ notice: Notice) -> String {
        switch notice {
        case .passTooLong(let seconds):
            return "dispatcher pass still running after \(seconds / 60) min (past its own cap)"
        case .noRecentPass(let seconds):
            return "no dispatcher pass has finished in \(seconds / 60) min"
        case .deadRunning(let count):
            return "\(count) running ledger row(s) have an agent pid that is gone"
        case .watchdogSilent(let seconds):
            return "the dispatcher watchdog has not checked in for \(seconds / 60) min"
        }
    }

    /// One signature per kind, so doctor and the alert dedupe treat each
    /// condition separately and the minute count does not re-page.
    static func signature(_ notice: Notice) -> String {
        switch notice {
        case .passTooLong: return "watchdog-pass-too-long"
        case .noRecentPass: return "watchdog-no-recent-pass"
        case .deadRunning: return "watchdog-dead-running"
        case .watchdogSilent: return "watchdog-silent"
        }
    }

    /// Rows count as dead only once an agent was spawned (`pid` recorded) and
    /// that pid is gone. A queued row (no pid yet) is not dead.
    static func deadRunningCount(rows: [(pid: Int32?, alive: Bool)]) -> Int {
        rows.filter { row in
            guard let pid = row.pid, pid > 1 else { return false }
            return !row.alive
        }.count
    }

    static func liveDeadRunningCount() -> Int {
        let rows = AuditDB.shared.dispatchRows(status: "running", limit: 100)
        return deadRunningCount(rows: rows.map { row in
            (pid: row.pid.map(Int32.init), alive: row.pid.map { AgentProcess.isAlive(Int32($0)) } ?? false)
        })
    }

    /// Signatures to page for: present now and not present at the last check.
    /// A condition that clears and comes back pages again.
    static func newAlerts(current: [Notice], previous: Set<String>) -> [Notice] {
        current.filter { !previous.contains(signature($0)) }
    }

    static func alertedURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("watchdog-alerted.json")
    }

    static func readAlerted(_ directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: alertedURL(directory)),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    static func writeAlerted(_ names: Set<String>, _ directory: URL) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: alertedURL(directory), options: .atomic)
    }

    /// Dead-man's switch, run by each dispatch pass: page once when an
    /// installed watchdog has gone quiet, and again only after it recovers.
    static func checkWatchdogAlive(now: Date, directory: URL = directory()) async {
        guard watchdogInstalled() else { return }
        let silent = notices(dispatcher: nil, watchdog: read(role: "watchdog", from: directory),
                             now: now, deadRunning: 0, maxPass: .infinity)
        var alerted = readAlerted(directory)
        let key = "dispatcher-saw-watchdog-silent"
        if let notice = silent.first {
            guard !alerted.contains(key) else { return }
            _ = await Notifier.push(title: "apple-tasks watchdog", body: summary(notice))
            alerted.insert(key)
        } else {
            guard alerted.contains(key) else { return }
            alerted.remove(key)
        }
        writeAlerted(alerted, directory)
    }
}

struct WatchdogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watchdog",
        abstract: "Check the dispatcher heartbeat and the ledger; push when a problem starts. No Reminders and no agents."
    )

    @Flag(name: .long, help: "Print nothing when the dispatcher looks healthy.")
    var quiet = false

    @Flag(name: .customLong("no-push"), help: "Report only; do not send notifications.")
    var noPush = false

    func run() async throws {
        let dir = Watchdog.directory()
        let dispatcher = Watchdog.read(role: "dispatcher", from: dir)
        let now = Date()
        let found = Watchdog.notices(
            dispatcher: dispatcher, watchdog: nil, now: now,
            deadRunning: Watchdog.liveDeadRunningCount(),
            maxPass: Watchdog.maxPassSeconds(config: try? AgentsConfig.load()))
        let beat = Watchdog.Beat(role: "watchdog", pid: ProcessInfo.processInfo.processIdentifier,
                                 started: Watchdog.stamp(now), finished: Watchdog.stamp(now))
        try Watchdog.write(beat, to: dir)

        if !noPush {
            var alerted = Watchdog.readAlerted(dir)
            for notice in Watchdog.newAlerts(current: found, previous: alerted) {
                _ = await Notifier.push(title: "apple-tasks watchdog", body: Watchdog.summary(notice))
            }
            // Keep the dispatcher's dead-man flag; replace the watchdog's own.
            alerted = alerted.filter { !$0.hasPrefix("watchdog-") }
                .union(found.map(Watchdog.signature))
            Watchdog.writeAlerted(alerted, dir)
        }
        if found.isEmpty && quiet { return }
        emit(found.map(Watchdog.summary))
    }
}
