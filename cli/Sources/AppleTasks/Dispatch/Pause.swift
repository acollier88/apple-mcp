import ArgumentParser
import Foundation

// MARK: - Duration (`30m`, `2h`, `1d`, `90s`)

enum DispatchDuration {
    /// Positive number plus a single unit suffix: `s` seconds, `m` minutes,
    /// `h` hours, `d` days. Suffix is case-insensitive.
    static func parse(_ raw: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let unitChar = trimmed.last else {
            throw AppleTasksError.invalidInput(Self.help)
        }
        let magnitude = trimmed.dropLast()
        guard let value = Double(magnitude), value.isFinite, value > 0 else {
            throw AppleTasksError.invalidInput(Self.help)
        }
        switch unitChar.lowercased() {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        default:
            throw AppleTasksError.invalidInput(Self.help)
        }
    }

    static let help = "duration must be a positive number plus s/m/h/d (e.g. 30m, 2h, 1d, 90s)"
}

// MARK: - Pause KV + gate

extension Dispatch {
    static let pausedUntilKey = "dispatch.pausedUntil"
    static let pauseReasonKey = "dispatch.pauseReason"
    static let pauseLastReportedKey = "dispatch.pauseLastReported"

    struct PauseState: Equatable {
        let until: Date
        let untilISO: String
        let reason: String?

        /// Identity used for `--quiet` last-reported collapse.
        var identity: String { "\(untilISO)\t\(reason ?? "")" }

        var action: String {
            if let reason { return "paused until \(untilISO) (\(reason))" }
            return "paused until \(untilISO)"
        }

        var report: DispatchReport {
            DispatchReport(taskId: "", title: "", agent: "", cwd: nil,
                           action: action, exitCode: nil, runLog: nil, worktree: nil)
        }
    }

    static func formatPausedUntil(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }

    /// Active pause, or nil if unset / empty / unparseable / already expired.
    /// Pure: no DB writes. `state` is a key→value snapshot of the KV table.
    static func pauseGate(now: Date, state: [String: String]) -> PauseState? {
        guard let raw = nonempty(state[pausedUntilKey]),
              let until = parseISO8601(raw), until > now else { return nil }
        return PauseState(until: until, untilISO: raw, reason: nonempty(state[pauseReasonKey]))
    }

    /// `--quiet` (launchd) only emits the paused report when until/reason
    /// changed since `dispatch.pauseLastReported`. A human (non-quiet) pass
    /// always includes it.
    static func shouldEmitPausedReport(quiet: Bool, lastReported: String?, pause: PauseState) -> Bool {
        !quiet || nonempty(lastReported) != pause.identity
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func pauseKV(_ db: AuditDB) -> [String: String] {
        var state: [String: String] = [:]
        if let v = db.getState(pausedUntilKey) { state[pausedUntilKey] = v }
        if let v = db.getState(pauseReasonKey) { state[pauseReasonKey] = v }
        if let v = db.getState(pauseLastReportedKey) { state[pauseLastReportedKey] = v }
        return state
    }

    /// Resolve the live pause, lazily clearing expired keys.
    static func resolvedPause(db: AuditDB, now: Date = Date()) -> PauseState? {
        let state = pauseKV(db)
        if let pause = pauseGate(now: now, state: state) { return pause }
        if nonempty(state[pausedUntilKey]) != nil || nonempty(state[pauseReasonKey]) != nil {
            clearPause(db)
        }
        return nil
    }

    static func clearPause(_ db: AuditDB) {
        db.setState(pausedUntilKey, "")
        db.setState(pauseReasonKey, "")
        db.setState(pauseLastReportedKey, "")
    }

    struct PauseOut: Codable {
        let paused: Bool
        let until: String
        let reason: String?
    }

    struct ResumeOut: Codable {
        let paused: Bool
        let wasPausedUntil: String?
    }

    struct StatusOut: Codable {
        let paused: Bool
        let until: String?
        let reason: String?
        let remainingSeconds: Int?
    }

    static func applyPause(db: AuditDB, until: Date, reason: String?, now: Date = Date()) throws -> PauseOut {
        guard until > now else {
            throw AppleTasksError.invalidInput("pause until must be in the future")
        }
        let iso = formatPausedUntil(until)
        let storedReason = nonempty(reason)
        db.setState(pausedUntilKey, iso)
        db.setState(pauseReasonKey, storedReason ?? "")
        // Force the next launchd `--quiet` pass to print the new pause line.
        db.setState(pauseLastReportedKey, "")
        return PauseOut(paused: true, until: iso, reason: storedReason)
    }

    static func applyResume(db: AuditDB) -> ResumeOut {
        let previous = nonempty(db.getState(pausedUntilKey)).flatMap { raw in
            parseISO8601(raw) != nil ? raw : nil
        }
        clearPause(db)
        return ResumeOut(paused: false, wasPausedUntil: previous)
    }

    static func applyStatus(db: AuditDB, now: Date = Date()) -> StatusOut {
        guard let pause = resolvedPause(db: db, now: now) else {
            return StatusOut(paused: false, until: nil, reason: nil, remainingSeconds: nil)
        }
        let remaining = max(Int(pause.until.timeIntervalSince(now)), 0)
        return StatusOut(paused: true, until: pause.untilISO, reason: pause.reason,
                         remainingSeconds: remaining)
    }
}

// MARK: - Leaf commands (not subcommands of `dispatch`)

struct DispatchPause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-pause",
        abstract: """
        Pause new dispatches until a time. Reap and worktree GC still run \
        on each launchd pass; digest is unaffected. Exactly one of --for \
        or --until is required.
        """
    )

    @Option(name: .customLong("for"), help: "How long to pause: 30m, 2h, 1d, 90s.")
    var forDuration: String?

    @Option(name: .customLong("until"), help: "ISO8601 resume time (timezone required, e.g. 2026-09-08T12:00:00Z).")
    var until: String?

    @Option(help: "Optional reason shown in dispatch-status, doctor, and the paused report.")
    var reason: String?

    func run() async throws {
        let untilDate: Date
        switch (forDuration, until) {
        case (let raw?, nil):
            untilDate = Date().addingTimeInterval(try DispatchDuration.parse(raw))
        case (nil, let raw?):
            guard let parsed = Dispatch.parseISO8601(raw) else {
                throw AppleTasksError.invalidInput(
                    "until must be ISO8601 with a timezone (e.g. 2026-09-08T12:00:00Z)")
            }
            untilDate = parsed
        default:
            throw AppleTasksError.invalidInput("exactly one of --for or --until is required")
        }
        let out = try Dispatch.applyPause(db: .shared, until: untilDate, reason: reason)
        AuditDB.shared.record(command: "dispatch-pause",
                              detail: out.reason.map { "\(out.until) (\($0))" } ?? out.until)
        emit(out)
    }
}

struct DispatchResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-resume",
        abstract: "Clear a dispatcher pause so the next pass can claim work again."
    )

    func run() async throws {
        let out = Dispatch.applyResume(db: .shared)
        AuditDB.shared.record(command: "dispatch-resume",
                              detail: out.wasPausedUntil, result: "ok")
        emit(out)
    }
}

struct DispatchStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch-status",
        abstract: "Whether the dispatcher is paused, until when, and seconds remaining."
    )

    func run() async throws {
        emit(Dispatch.applyStatus(db: .shared))
    }
}
