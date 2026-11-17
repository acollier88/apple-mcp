import ArgumentParser
import Foundation

/// A second, tiny checker for the dispatcher (#56). It reads two heartbeat
/// files and the ledger. It does not touch EventKit or start an agent.
enum Watchdog {
    static let maxPassSeconds: TimeInterval = 30 * 60
    static let maxSilenceSeconds: TimeInterval = 15 * 60

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

    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(_ stamp: String) -> Date? {
        ISO8601DateFormatter().date(from: stamp)
    }

    static func write(_ beat: Beat, to directory: URL) throws {
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

    static func notices(dispatcher: Beat?, watchdog: Beat?, now: Date,
                        deadRunning: Int,
                        maxPass: TimeInterval = maxPassSeconds,
                        maxSilence: TimeInterval = maxSilenceSeconds) -> [Notice] {
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
        if let watchdog, let finished = watchdog.finished.flatMap(date) ?? date(watchdog.started) {
            let quiet = now.timeIntervalSince(finished)
            if quiet > maxSilence { found.append(.watchdogSilent(Int(quiet))) }
        }
        return found
    }

    static func summary(_ notice: Notice) -> String {
        switch notice {
        case .passTooLong(let seconds):
            return "dispatcher pass still running after \(seconds)s"
        case .noRecentPass(let seconds):
            return "no dispatcher pass finished in \(seconds)s"
        case .deadRunning(let count):
            return "\(count) running ledger row(s) have a pid that is gone"
        case .watchdogSilent(let seconds):
            return "watchdog has not checked in for \(seconds)s"
        }
    }

    static func deadRunningCount(rows: [(pid: Int32?, alive: Bool)]) -> Int {
        rows.filter { row in
            guard let pid = row.pid else { return true }
            return !row.alive && pid > 0
        }.count
    }
}

struct WatchdogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watchdog",
        abstract: "Check the dispatcher heartbeat and the ledger. No Reminders and no agents."
    )

    @Flag(name: .long, help: "Print nothing when the dispatcher looks healthy.")
    var quiet = false

    func run() throws {
        let dir = Watchdog.directory()
        let dispatcher = Watchdog.read(role: "dispatcher", from: dir)
        let previous = Watchdog.read(role: "watchdog", from: dir)
        let rows = AuditDB.shared.dispatchRows(status: "running", limit: 100)
        let dead = Watchdog.deadRunningCount(rows: rows.map { row in
            (pid: row.pid.map(Int32.init), alive: row.pid.map { AgentProcess.isAlive(Int32($0)) } ?? false)
        })
        let now = Date()
        let found = Watchdog.notices(dispatcher: dispatcher, watchdog: previous, now: now, deadRunning: dead)
        let beat = Watchdog.Beat(role: "watchdog", pid: ProcessInfo.processInfo.processIdentifier,
                                 started: Watchdog.stamp(now), finished: Watchdog.stamp(now))
        try Watchdog.write(beat, to: dir)
        if found.isEmpty && quiet { return }
        emit(found.map(Watchdog.summary))
    }
}
