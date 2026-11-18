import CryptoKit
import Foundation

/// Spare-capacity research (#48). Detectors read a snapshot and propose
/// tasks. They never launch an agent: a research agent would need the
/// sandbox from #39, which is not available here. A proposal has no [auto]
/// tag, so dispatch will not pick it up.
enum ResearchDetectors {
    struct Run: Equatable {
        var id: Int
        var agent: String
        var status: String
    }

    struct Proposal: Codable, Equatable {
        var fingerprint: String
        var detector: String
        var title: String
        var evidence: String

        var evidenceHash: String {
            let digest = SHA256.hash(data: Data(evidence.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Stored: Equatable {
        var evidenceHash: String
        var status: String
    }

    enum Decision: Equatable {
        case record
        case reopen
        case skip
    }

    /// Nil when research may run. Budget must be green, the clock must be
    /// inside configured quiet hours, and a concurrency slot must be free.
    static func gate(budget: String?, quiet: String, running: Int, maxConcurrent: Int) -> String? {
        guard budget == "green" else {
            if let budget { return "budget is \(budget)" }
            return "budget snapshot missing or not green"
        }
        guard quiet == "inside" else {
            if quiet == "unconfigured" { return "quiet hours are not configured" }
            if quiet == "invalid" { return "quiet hours are invalid" }
            return "outside quiet hours"
        }
        let cap = max(maxConcurrent, 1)
        guard running < cap else { return "no spare concurrency (\(running)/\(cap))" }
        return nil
    }

    static func spareBudget(_ snap: BudgetBandwidth?) -> String? {
        guard let snap else { return nil }
        let tiers = snap.providers.values.compactMap(\.usableTier)
        guard !tiers.isEmpty else { return nil }
        if tiers.allSatisfy({ $0 == "green" }) { return "green" }
        if tiers.contains(where: { $0 == "red" }) { return "red" }
        return "yellow"
    }

    static func quietState(_ window: TimeWindow?, now: Date = Date()) -> String {
        guard let window else { return "unconfigured" }
        switch window.check(now: now) {
        case .inside: return "inside"
        case .outside: return "outside"
        case .invalid: return "invalid"
        }
    }

    static func candidates(runs: [Run], openAutoCount: Int, lastDispatchAt: Date?,
                           now: Date, staleDays: Int = 7, streak: Int = 3) -> [Proposal] {
        var out: [Proposal] = []
        let byAgent = Dictionary(grouping: runs, by: \.agent)
        for agent in byAgent.keys.sorted() {
            let ordered = byAgent[agent, default: []].sorted { $0.id > $1.id }
            var failing: [Run] = []
            for run in ordered {
                if run.status == "failed" || run.status == "timeout" {
                    failing.append(run)
                } else {
                    break
                }
            }
            guard failing.count >= streak else { continue }
            let evidence = failing.prefix(streak).map { "#\($0.id) \($0.status)" }.joined(separator: "; ")
            out.append(Proposal(
                fingerprint: "lane-streak:\(agent)",
                detector: "lane-streak",
                title: "Proposal: \(agent) has \(failing.count) failed runs in a row",
                evidence: evidence))
        }
        if openAutoCount > 0 {
            let limit = TimeInterval(staleDays) * 86400
            let silent = lastDispatchAt.map { now.timeIntervalSince($0) > limit } ?? true
            if silent {
                let when = lastDispatchAt.map { "last dispatch \($0)" } ?? "no dispatch rows"
                out.append(Proposal(
                    fingerprint: "dispatcher-silent",
                    detector: "dispatcher-silent",
                    title: "Proposal: dispatcher has been silent while \(openAutoCount) auto tasks are open",
                    evidence: "\(when); open auto tasks \(openAutoCount)"))
            }
        }
        return out
    }

    static func decide(_ proposal: Proposal, stored: Stored?) -> Decision {
        guard let stored else { return .record }
        if stored.status == "proposed" { return .skip }
        if stored.evidenceHash == proposal.evidenceHash { return .skip }
        return .reopen
    }
}
