import Foundation

/// How `[auto]`-only dispatch treats premium bandwidth from
/// `~/.config/budget-tracker/latest.json`.
enum AutoBudgetMode: String {
    /// Ignore the snapshot (default walk only).
    case off
    /// Skip a provider when its usable lane is red (>90%). Yellow still runs, sorted later.
    case skipRed
    /// Skip yellow and red.
    case skipYellow

    static func parse(_ raw: String?) -> AutoBudgetMode {
        switch (raw ?? "skipRed").lowercased() {
        case "off", "none", "false": return .off
        case "skipyellow", "skip-yellow": return .skipYellow
        default: return .skipRed
        }
    }

    var skipFromRank: Int {
        switch self {
        case .off: return 99
        case .skipRed: return 2
        case .skipYellow: return 1
        }
    }
}

/// Mirror of Budget Tracker's bandwidth snapshot. Independent of that app's
/// sources — schemaVersion 1 is the contract.
///
/// Cursor and Antigravity use `combine: "any"` (two independent percentage
/// lanes). Claude and Copilot use `combine: "all"` (stacked constraints).
struct BudgetBandwidth: Codable {
    var schemaVersion: Int
    var updatedAt: String
    var providers: [String: Provider]

    struct Provider: Codable {
        var combine: String
        var lanes: [Lane]

        var usablePercent: Double? {
            let percents = lanes.map(\.percentUsed)
            guard !percents.isEmpty else { return nil }
            return combine.lowercased() == "any" ? percents.min() : percents.max()
        }

        var usableTier: String? {
            usablePercent.map { Self.tierName(for: $0) }
        }

        static func tierName(for percent: Double) -> String {
            if percent >= 90 { return "red" }
            if percent >= 70 { return "yellow" }
            return "green"
        }
    }

    struct Lane: Codable {
        var id: String
        var name: String
        var percentUsed: Double
        var tier: String
        var remainingPercent: Double
    }

    static let staleAfter: TimeInterval = 15 * 60

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/budget-tracker/latest.json")
    }

    /// nil when missing, unreadable, or older than `maxAge` (fail open).
    static func load(
        url: URL = defaultURL,
        now: Date = Date(),
        maxAge: TimeInterval = staleAfter
    ) -> BudgetBandwidth? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(BudgetBandwidth.self, from: data)
        else { return nil }
        guard let stamped = parseStamp(snap.updatedAt) else { return nil }
        if now.timeIntervalSince(stamped) > maxAge { return nil }
        return snap
    }

    /// Load even when stale; caller reports age. nil only if the file is missing/unreadable.
    static func loadAllowingStale(url: URL = defaultURL, now: Date = Date()) -> (snap: BudgetBandwidth, age: TimeInterval)? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(BudgetBandwidth.self, from: data),
              let stamped = parseStamp(snap.updatedAt)
        else { return nil }
        return (snap, now.timeIntervalSince(stamped))
    }

    private static func parseStamp(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }

    /// apple-tasks lane tag → snapshot provider key. Local/ops lanes return nil.
    static func providerKey(forAgent tag: String) -> String? {
        switch tag.lowercased() {
        case "cursor", "claude", "antigravity", "copilot": return tag.lowercased()
        default: return nil
        }
    }

    static func tierRank(_ tier: String?) -> Int {
        switch tier {
        case "green": return 0
        case "yellow": return 1
        case "red": return 2
        default: return 0
        }
    }

    /// Prefer greener usable lanes; keep relative order among equals (stable).
    func ordered(_ tags: [String]) -> [String] {
        tags.enumerated().sorted { a, b in
            let ra = rank(a.element)
            let rb = rank(b.element)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    func rank(_ agentTag: String) -> Int {
        guard let key = Self.providerKey(forAgent: agentTag),
              let provider = providers[key] else { return 0 }
        return Self.tierRank(provider.usableTier)
    }

    /// nil = do not skip (missing provider, empty lanes, or under the threshold).
    func skipReason(agentTag: String, mode: AutoBudgetMode) -> String? {
        guard mode != .off,
              let key = Self.providerKey(forAgent: agentTag),
              let provider = providers[key],
              !provider.lanes.isEmpty,
              let percent = provider.usablePercent,
              let tier = provider.usableTier
        else { return nil }
        let rank = Self.tierRank(tier)
        guard rank >= mode.skipFromRank else { return nil }
        let lanes = provider.lanes
            .map { "\($0.name) \(Int($0.percentUsed))% \($0.tier)" }
            .joined(separator: "; ")
        return "budget: usable \(Int(percent))% \(tier) via \(provider.combine) [\(lanes)]"
    }
}
