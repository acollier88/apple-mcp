import ArgumentParser
import CryptoKit
import Foundation

/// Inbox over proposable findings (#53). Dismissal stays on the fingerprint
/// until the evidence hash changes. Accepting is what creates a task, and
/// `[auto]` is added only when this detector names a lane.
enum ProposalsInbox {
    static let modelSnapshot = "model-snapshot"
    static let muteKey = "findings.muted"
    static let muteAfter = 10
    static let muteBelow = 0.20

    struct Item: Codable, Equatable {
        var id: Int
        var fingerprint: String
        var detector: String
        var summary: String
        var evidence: String
        var lane: String?
        var attempts: Int
    }

    struct ListOut: Codable {
        var proposals: [Item]
        var muted: [String]
    }

    struct AcceptOut: Codable {
        var id: Int
        var taskId: String
        var title: String
        var tags: [String]
        var list: String
    }

    struct DismissOut: Codable {
        var id: Int
        var state: String
        var muted: Bool
    }

    static func fingerprint(detector: String, kind: String, title: String) -> String {
        let raw = "\(detector)\n\(kind)\n\(title)"
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(detector):\(hash.prefix(16))"
    }

    static func lane(from action: String?) -> String? {
        guard let action, action.hasPrefix("lane:") else { return nil }
        let name = String(action.dropFirst("lane:".count))
        return name.isEmpty ? nil : name
    }

    /// A named lane is what makes an accepted proposal eligible to dispatch.
    static func tags(lane: String?) -> [String] {
        guard let lane, !lane.isEmpty else { return [] }
        return ["auto", lane]
    }

    static func visible(_ rows: [AuditDB.FindingRow], muted: Set<String>) -> [AuditDB.FindingRow] {
        rows.filter {
            $0.findingClass == "proposable" && $0.state == "open" && !muted.contains($0.detector)
        }
    }

    /// Muted once ten proposals have been decided and fewer than one in five were accepted.
    static func shouldMute(accepted: Int, decided: Int) -> Bool {
        guard decided >= muteAfter, decided > 0 else { return false }
        return Double(accepted) / Double(decided) < muteBelow
    }

    static func muted(db: AuditDB = .shared) -> Set<String> {
        guard let raw = db.getState(muteKey),
              let names = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
            return []
        }
        return Set(names)
    }

    static func setMuted(_ names: Set<String>, db: AuditDB = .shared) {
        let data = (try? JSONEncoder().encode(names.sorted())) ?? Data("[]".utf8)
        _ = db.setState(muteKey, String(data: data, encoding: .utf8) ?? "[]")
    }

    @discardableResult
    /// `fingerprint` overrides the title-derived one for detectors whose
    /// title carries a changing count (research: "4 failed runs in a row").
    static func remember(detector: String, kind: String, title: String, evidence: String,
                         lane: String?, fingerprint explicit: String? = nil,
                         db: AuditDB = .shared) -> String {
        let fp = explicit ?? fingerprint(detector: detector, kind: kind, title: title)
        let body = "kind: \(kind)\n\(evidence)"
        return db.observeFinding(
            fingerprint: fp, detector: detector, system: "proposals", severity: "notice",
            findingClass: Findings.Kind.proposable.rawValue, summary: title, evidence: body,
            evidenceHash: Findings.Finding(
                detector: detector, fingerprint: fp, system: "proposals", severity: "notice",
                kind: .proposable, summary: title, evidence: body, action: ""
            ).evidenceHash,
            action: lane.map { "lane:\($0)" })
    }

    static func list(db: AuditDB = .shared) -> ListOut {
        let quiet = muted(db: db)
        let rows = visible(db.findings(findingClass: Findings.Kind.proposable.rawValue, limit: 200), muted: quiet)
        return ListOut(
            proposals: rows.map(item),
            muted: quiet.sorted())
    }

    static func accept(id: Int, listName: String, store: Store, db: AuditDB = .shared) throws -> AcceptOut {
        let row = try openProposal(id: id, db: db)
        let lane = lane(from: row.action)
        let tags = tags(lane: lane)
        let notes = """
        Proposed by \(row.detector).
        \(row.evidence)
        fingerprint: \(row.fingerprint)
        """
        let task = try createTask(
            store: store, listName: listName, title: row.summary, tags: tags, notes: notes,
            due: nil, priority: nil, url: nil, recurrence: nil, mirrorNativeTags: true,
            auditCommand: "proposal-accept")
        guard db.setFindingState(fingerprint: row.fingerprint, state: "accepted") else {
            throw AppleTasksError.saveFailed("accepted the task but could not record finding \(id)")
        }
        considerMute(detector: row.detector, db: db)
        return AcceptOut(id: id, taskId: task.id, title: task.title, tags: tags, list: task.list)
    }

    static func dismiss(id: Int, muteDetector: Bool, db: AuditDB = .shared) throws -> DismissOut {
        let row = try openProposal(id: id, db: db)
        guard db.setFindingState(fingerprint: row.fingerprint, state: "dismissed") else {
            throw AppleTasksError.saveFailed("could not dismiss finding \(id)")
        }
        if muteDetector {
            var names = muted(db: db)
            names.insert(row.detector)
            setMuted(names, db: db)
        } else {
            considerMute(detector: row.detector, db: db)
        }
        return DismissOut(id: id, state: "dismissed", muted: muted(db: db).contains(row.detector))
    }

    static func unmute(_ detector: String, db: AuditDB = .shared) {
        var names = muted(db: db)
        names.remove(detector)
        setMuted(names, db: db)
    }

    static func considerMute(detector: String, db: AuditDB = .shared) {
        let rows = db.findings(findingClass: Findings.Kind.proposable.rawValue, limit: 500)
            .filter { $0.detector == detector && ($0.state == "accepted" || $0.state == "dismissed") }
        let accepted = rows.filter { $0.state == "accepted" }.count
        guard shouldMute(accepted: accepted, decided: rows.count) else { return }
        var names = muted(db: db)
        names.insert(detector)
        setMuted(names, db: db)
    }

    static func mutedIssues(db: AuditDB = .shared) -> [DoctorIssue] {
        muted(db: db).sorted().map { name in
            DoctorIssue(
                system: "proposals", severity: "info",
                summary: "detector \(name) is muted (accept rate under 20% after 10 proposals); apple-tasks proposals unmute \(name)",
                signature: "muted:\(name)")
        }
    }

    static func rememberSuggestions(_ suggestions: [SuggestionOut], lane: String?,
                                    db: AuditDB = .shared) {
        for suggestion in suggestions {
            remember(detector: modelSnapshot, kind: suggestion.kind, title: suggestion.title,
                     evidence: suggestion.reason, lane: lane, db: db)
        }
    }

    private static func openProposal(id: Int, db: AuditDB) throws -> AuditDB.FindingRow {
        guard let row = db.findings(limit: 500).first(where: { $0.id == id }) else {
            throw AppleTasksError.saveFailed("no finding \(id)")
        }
        guard row.findingClass == Findings.Kind.proposable.rawValue, row.state == "open" else {
            throw AppleTasksError.saveFailed("finding \(id) is \(row.state), not an open proposal")
        }
        return row
    }

    private static func item(_ row: AuditDB.FindingRow) -> Item {
        Item(id: row.id, fingerprint: row.fingerprint, detector: row.detector,
             summary: row.summary, evidence: row.evidence, lane: lane(from: row.action),
             attempts: row.attempts)
    }
}

struct Proposals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proposals",
        abstract: "Proposals inbox. Accept creates a task; dismiss stays quiet until the evidence changes.",
        subcommands: [ProposalsList.self, ProposalsAccept.self, ProposalsDismiss.self, ProposalsUnmute.self],
        defaultSubcommand: ProposalsList.self
    )
}

struct ProposalsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Open proposals, skipping muted detectors.")

    func run() throws {
        emit(ProposalsInbox.list())
    }
}

struct ProposalsAccept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accept",
        abstract: "Create a task from an open proposal. [auto] is added only when the detector names a lane.")

    @Argument(help: "Finding id from `proposals list`.")
    var id: Int

    @Option(help: "Reminders list for the new task.")
    var list: String = "Code Tasks"

    func run() async throws {
        // Accepting can create an [auto] task; deciding proposals is the human's call.
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "proposals accept", caller: CallerGuard.currentCaller),
            command: "proposals accept", detail: nil)
        let store = Store()
        try await store.requestAccess()
        emit(try ProposalsInbox.accept(id: id, listName: list, store: store))
    }
}

struct ProposalsDismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Remember a rejection. The same evidence will not be proposed again.")

    @Argument(help: "Finding id from `proposals list`.")
    var id: Int

    @Flag(name: .customLong("mute-detector"),
          help: "Stop surfacing every open proposal from this detector.")
    var muteDetector = false

    func run() throws {
        // Accepting can create an [auto] task; deciding proposals is the human's call.
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "proposals dismiss", caller: CallerGuard.currentCaller),
            command: "proposals dismiss", detail: nil)
        emit(try ProposalsInbox.dismiss(id: id, muteDetector: muteDetector))
    }
}

struct ProposalsUnmute: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmute",
        abstract: "Show a detector's proposals again.")

    @Argument var detector: String

    func run() throws {
        // Accepting can create an [auto] task; deciding proposals is the human's call.
        try CallerGuard.enforce(
            CallerGuard.reviewRefusal(command: "proposals unmute", caller: CallerGuard.currentCaller),
            command: "proposals unmute", detail: nil)
        ProposalsInbox.unmute(detector)
        emit(ProposalsInbox.list())
    }
}
