import Foundation

/// What happens after a healable finding is still present (#55).
/// The same evidence never repeats a rung. A clean re-check is the only
/// thing that counts as healed. Too many heals in a day pauses the ladder.
enum HealPolicy {
    static let levelPrefix = "heal.level."
    static let breakerKey = "heal.breaker.day"

    enum Action: Equatable {
        case quiet
        case playbook(String)
        case agent
        case needsHuman(String)
        case breaker
    }

    struct ReportRow: Codable, Equatable {
        var fingerprint: String
        var state: String
        var attempts: Int
        var level: String?
    }

    static func dayStamp(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func decide(fingerprint: String, rung: Playbooks.Rung, previous: String?,
                       evidenceChanged: Bool, healsToday: Int, cap: Int) -> Action {
        if healsToday >= max(cap, 0) { return .breaker }
        if previous != nil && !evidenceChanged { return .quiet }
        switch rung {
        case .needsHuman(let id):
            return .needsHuman(id)
        case .agent:
            return (previous == "agent" || previous == "human") ? .needsHuman(fingerprint) : .agent
        case .playbook(let id):
            if previous == nil { return .playbook(id) }
            if previous == "playbook" { return .agent }
            return .needsHuman(fingerprint)
        }
    }

    /// A heal counts only when the detector comes back clean.
    static func verified(clean: Bool) -> String {
        clean ? "healed" : "open"
    }

    static func levelKey(_ fingerprint: String) -> String {
        levelPrefix + fingerprint
    }

    static func remember(_ action: Action, fingerprint: String, db: AuditDB = .shared) {
        let stored: String?
        switch action {
        case .playbook: stored = "playbook"
        case .agent: stored = "agent"
        case .needsHuman: stored = "human"
        case .quiet, .breaker: stored = nil
        }
        if let stored { _ = db.setState(levelKey(fingerprint), stored) }
    }

    static func report(_ rows: [AuditDB.FindingRow], level: (String) -> String?) -> [ReportRow] {
        rows.filter { $0.findingClass == Findings.Kind.healable.rawValue && $0.state == "open" }
            .map { row in
                ReportRow(fingerprint: row.fingerprint, state: row.state,
                          attempts: row.attempts, level: level(row.fingerprint))
            }
    }
}
