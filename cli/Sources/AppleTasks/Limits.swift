import ArgumentParser
import Foundation

/// `limits` in agents.json (#68). Absent or `0` = no cap. Days are local
/// calendar days; a cap that is reached holds claims until local midnight.
/// `maxConcurrent` (top level and per lane) already bounds parallel runs.
struct DispatchLimits: Codable, Equatable {
    /// Claims per day across every lane.
    var maxPerDay: Int?
    /// Claims per day for a named lane, e.g. `{"claude": 10}`.
    var maxPerLanePerDay: [String: Int]?
    /// Claims per day of tasks a human did not create (doctor heals, GitHub
    /// sync, MCP and agent callers). See `Limits.origin`.
    var maxAutomatedPerDay: Int?
}

enum Limits {
    // MARK: Origin

    static let human = "human"

    /// Who created the task, from its creating audit row. Tasks made outside
    /// apple-tasks (Reminders, Siri, mail rules) have none and count as human;
    /// so does `proposals accept`, which only the human can run.
    static func origin(tags: [String], creation: (caller: String, command: String)?) -> String {
        if let creation {
            switch creation.command {
            case "doctor-heal": return "doctor"
            case "sync-github": return "github"
            case "proposal-accept": return human
            default:
                if CallerGuard.isAutomated(creation.caller) {
                    return creation.caller.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                return human
            }
        }
        return tags.contains { $0.lowercased() == "heal" } ? "doctor" : human
    }

    static func isAutomated(origin: String) -> Bool { origin != human }

    // MARK: Gate

    enum Hit: Equatable {
        case total(cap: Int)
        case automated(cap: Int)
        case lane(String, cap: Int)

        var signature: String {
            switch self {
            case .total: return "limit:total"
            case .automated: return "limit:automated"
            case .lane(let lane, _): return "limit:lane:\(lane)"
            }
        }

        var reason: String {
            switch self {
            case .total(let cap): return "gated: daily dispatch limit reached (\(cap))"
            case .automated(let cap): return "gated: daily limit for automated tasks reached (\(cap))"
            case .lane(let lane, let cap): return "gated: daily limit for \(lane) reached (\(cap))"
            }
        }

        var key: String {
            switch self {
            case .total: return "limits.maxPerDay"
            case .automated: return "limits.maxAutomatedPerDay"
            case .lane(let lane, _): return "limits.maxPerLanePerDay.\(lane)"
            }
        }
    }

    static func cap(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Pass-wide caps for one task, before a lane is chosen.
    static func taskHit(limits: DispatchLimits?, total: Int, automated: Int, origin: String) -> Hit? {
        if let cap = cap(limits?.maxPerDay), total >= cap { return .total(cap: cap) }
        if isAutomated(origin: origin), let cap = cap(limits?.maxAutomatedPerDay), automated >= cap {
            return .automated(cap: cap)
        }
        return nil
    }

    static func laneHit(limits: DispatchLimits?, lane: String, count: Int) -> Hit? {
        guard let cap = cap(limits?.maxPerLanePerDay?[lane]), count >= cap else { return nil }
        return .lane(lane, cap: cap)
    }

    static func dayStart(_ now: Date = Date(), calendar: Calendar = .current) -> String {
        ISO8601DateFormatter().string(from: calendar.startOfDay(for: now))
    }

    static func localDay(_ now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Alert once per limit per day

    static let alertedKey = "limits.alerted"

    /// Signatures not yet alerted today, and the record to store afterwards.
    static func newAlerts(_ hits: [Hit], stored: String?, day: String) -> (fresh: [Hit], record: String) {
        var seen: Set<String> = []
        if let stored, stored.hasPrefix(day + "|") {
            seen = Set(stored.dropFirst(day.count + 1).split(separator: ",").map(String.init))
        }
        var fresh: [Hit] = []
        for hit in hits where seen.insert(hit.signature).inserted { fresh.append(hit) }
        return (fresh, day + "|" + seen.sorted().joined(separator: ","))
    }

    static func alert(_ hits: [Hit], db: AuditDB = .shared, now: Date = Date()) async {
        guard !hits.isEmpty else { return }
        let (fresh, record) = newAlerts(hits, stored: db.getState(alertedKey), day: localDay(now))
        _ = db.setState(alertedKey, record)
        for hit in fresh {
            let text = String(hit.reason.dropFirst("gated: ".count))
            db.record(command: "limit-reached", detail: text)
            _ = await Notifier.push(
                title: "Needs you",
                body: "Dispatch \(text). Claims resume after midnight, or raise \(hit.key) in agents.json.")
        }
    }

    // MARK: Stop (kill switch)

    static let stoppedKey = "dispatch.stopped"
    static let stopReasonPrefix = "stopped"
    /// `stop --all` pauses for this long; `dispatch-resume` ends it.
    static let stopPause: TimeInterval = 3650 * 86_400

    /// Set by `stop --all`; cleared by `dispatch-resume`. While set, proactive
    /// seats (`research run`, `doctor --enqueue-heals` and its playbooks) do
    /// nothing. `heal --run` stays available to the human.
    static func stopped(db: AuditDB = .shared) -> String? {
        Dispatch.nonempty(db.getState(stoppedKey))
    }

    static let stoppedReason = "stopped with `apple-tasks stop --all`; run `apple-tasks dispatch-resume` to restart"

    // MARK: Status (doctor)

    struct Status: Codable, Equatable {
        var day: String
        var total: Int
        var automated: Int
        var perLane: [String: Int]
        var maxPerDay: Int?
        var maxAutomatedPerDay: Int?
        var maxPerLanePerDay: [String: Int]?
        var reached: [String]
        var stoppedAt: String?
    }

    /// Every cap at or over its count today.
    static func reached(limits: DispatchLimits?, lanes: [String], db: AuditDB = .shared,
                        now: Date = Date()) -> [Hit] {
        let since = dayStart(now)
        var hits: [Hit] = []
        if let cap = cap(limits?.maxPerDay), db.dispatchCount(since: since) >= cap {
            hits.append(.total(cap: cap))
        }
        if let cap = cap(limits?.maxAutomatedPerDay), db.dispatchCount(since: since, automatedOnly: true) >= cap {
            hits.append(.automated(cap: cap))
        }
        for lane in lanes.sorted() {
            if let hit = laneHit(limits: limits, lane: lane, count: db.dispatchCount(since: since, agent: lane)) {
                hits.append(hit)
            }
        }
        return hits
    }

    static func status(limits: DispatchLimits?, lanes: [String], db: AuditDB = .shared, now: Date = Date()) -> Status {
        let since = dayStart(now)
        let total = db.dispatchCount(since: since)
        let automated = db.dispatchCount(since: since, automatedOnly: true)
        var perLane: [String: Int] = [:]
        for lane in lanes.sorted() {
            let count = db.dispatchCount(since: since, agent: lane)
            if count > 0 { perLane[lane] = count }
        }
        let reached = reached(limits: limits, lanes: lanes, db: db, now: now).map(\.signature)
        return Status(day: localDay(now), total: total, automated: automated, perLane: perLane,
                      maxPerDay: cap(limits?.maxPerDay), maxAutomatedPerDay: cap(limits?.maxAutomatedPerDay),
                      maxPerLanePerDay: limits?.maxPerLanePerDay, reached: reached,
                      stoppedAt: stopped(db: db))
    }
}

// MARK: - stop --all

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: """
        Kill switch: pause claiming, cancel every running dispatch, and turn \
        off research, heal enqueue and playbooks until `dispatch-resume`.
        """
    )

    @Flag(name: .customLong("all"), help: "Required: stop everything.")
    var all = false

    @Option(help: "Reason shown in dispatch-status and doctor.")
    var reason: String?

    struct Out: Codable {
        let stopped: Bool
        let pausedUntil: String
        let cancelled: [DispatchCancel.Result]
        let note: String
    }

    func run() async throws {
        guard all else {
            throw AppleTasksError.invalidInput("stop needs --all (pause + cancel every running dispatch)")
        }
        // The kill switch is the human's (app, menu bar, MCP host, HTTP, terminal).
        // A dispatched agent cancelling every other run is a denial of service.
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "stop --all", caller: CallerGuard.currentCaller),
            command: "stop", detail: reason)
        let db = AuditDB.shared
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        _ = db.setState(Limits.stoppedKey, stamp)
        let text = [Limits.stopReasonPrefix, reason].compactMap { $0 }.joined(separator: ": ")
        let pause = try Dispatch.applyPause(db: db, until: now.addingTimeInterval(Limits.stopPause),
                                            reason: text, now: now)
        var cancelled: [DispatchCancel.Result] = []
        let store = Store()
        let storeReady = (try? await store.requestAccess()) != nil
        for row in db.dispatchRows(status: "running", limit: 1000) {
            cancelled.append(await Dispatch.cancelRunning(row: row, store: storeReady ? store : nil))
        }
        db.record(command: "stop", detail: "\(text); cancelled \(cancelled.count)")
        emit(Out(stopped: true, pausedUntil: pause.until, cancelled: cancelled,
                 note: "Run `apple-tasks dispatch-resume` from your own terminal to restart."))
    }
}
