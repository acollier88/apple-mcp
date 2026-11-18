import ArgumentParser
import EventKit
import Foundation

struct Research: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research",
        abstract: """
        When budget is green, quiet hours are in effect, and a dispatch slot \
        is free, record proposals from ledger patterns. Proposals are not \
        tasks and are not tagged [auto]. Nothing is dispatched. Accept one \
        to create an untagged reminder.
        """,
        subcommands: [ResearchRun.self, ResearchList.self, ResearchAccept.self, ResearchDismiss.self],
        defaultSubcommand: ResearchRun.self
    )
}

struct ResearchOut: Codable {
    let ran: Bool
    let reason: String?
    let dryRun: Bool
    let recorded: [Proposals.Proposal]
    let skipped: [String]
}

struct ResearchRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Record new proposals when the spare-capacity gates pass."
    )

    @Flag(name: .customLong("dry-run"), help: "Show what would be recorded. Writes nothing.")
    var dryRun = false

    func run() async throws {
        let config = try? AgentsConfig.load()
        let budget = Proposals.spareBudget(BudgetBandwidth.load())
        let quiet = Proposals.quietState(NotifyConfig.load()?.quietHours)
        let running = AuditDB.shared.dispatchRows(status: "running", limit: 100).count
        let cap = config?.maxConcurrent ?? 1
        if let reason = Proposals.gate(budget: budget, quiet: quiet, running: running, maxConcurrent: cap) {
            emit(ResearchOut(ran: false, reason: reason, dryRun: dryRun, recorded: [], skipped: []))
            return
        }
        let runs = AuditDB.shared.dispatchRows(status: nil, limit: 200).map {
            Proposals.Run(id: $0.id, agent: $0.agent, status: $0.status)
        }
        let last = AuditDB.shared.dispatchRows(status: nil, limit: 1).first
        let lastAt = last.flatMap { ResearchClock.date($0.startedAt) }
        let openAuto = await ResearchClock.openAutoCount()
        let found = Proposals.candidates(runs: runs, openAutoCount: openAuto, lastDispatchAt: lastAt, now: Date())
        var recorded: [Proposals.Proposal] = []
        var skipped: [String] = []
        for proposal in found {
            let stored = AuditDB.shared.proposal(fingerprint: proposal.fingerprint).map {
                Proposals.Stored(evidenceHash: $0.evidenceHash, status: $0.status)
            }
            switch Proposals.decide(proposal, stored: stored) {
            case .skip:
                skipped.append(proposal.fingerprint)
            case .record, .reopen:
                if dryRun {
                    recorded.append(proposal)
                } else if AuditDB.shared.saveProposal(
                    fingerprint: proposal.fingerprint, detector: proposal.detector,
                    title: proposal.title, evidence: proposal.evidence,
                    evidenceHash: proposal.evidenceHash, status: "proposed") {
                    recorded.append(proposal)
                } else {
                    skipped.append(proposal.fingerprint)
                }
            }
        }
        emit(ResearchOut(ran: true, reason: nil, dryRun: dryRun, recorded: recorded, skipped: skipped))
    }
}

struct ResearchList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List proposals. Defaults to ones still waiting."
    )

    @Option(name: .long, help: "proposed | dismissed | accepted | all")
    var status: String = "proposed"

    func run() throws {
        let rows = AuditDB.shared.proposals(status: status == "all" ? nil : status, limit: 100)
        emit(rows)
    }
}

struct ResearchDismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Remember a proposal as dismissed. The same evidence will not be raised again."
    )

    @Argument var fingerprint: String

    func run() throws {
        guard AuditDB.shared.setProposalStatus(fingerprint: fingerprint, status: "dismissed") else {
            throw AppleTasksError.invalidInput("no proposal \(fingerprint)")
        }
        emit(["fingerprint": fingerprint, "status": "dismissed"])
    }
}

struct ResearchAccept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accept",
        abstract: "Create an untagged reminder from a proposal. It is not [auto], so dispatch will not run it."
    )

    @Argument var fingerprint: String

    @Option(name: .customLong("list"), help: "Reminders list (default: Code Tasks).")
    var listName: String = "Code Tasks"

    func run() async throws {
        guard let row = AuditDB.shared.proposal(fingerprint: fingerprint) else {
            throw AppleTasksError.invalidInput("no proposal \(fingerprint)")
        }
        guard row.status == "proposed" else {
            throw AppleTasksError.invalidInput("proposal \(fingerprint) is \(row.status)")
        }
        let store = Store()
        try await store.requestAccess()
        let notes = """
        proposal-fingerprint: \(row.fingerprint)

        \(row.evidence)

        This reminder was accepted from research. It has no [auto] tag. Add [auto] yourself if you want dispatch to run it.
        """
        let out = try createTask(
            store: store, listName: listName, title: row.title, tags: [],
            notes: notes, due: nil, priority: .medium, url: nil,
            recurrence: nil, mirrorNativeTags: false, auditCommand: "research-accept")
        guard AuditDB.shared.setProposalStatus(fingerprint: fingerprint, status: "accepted") else {
            throw AppleTasksError.saveFailed("created \(out.id) but could not mark the proposal accepted")
        }
        emit(out)
    }
}

enum ResearchClock {
    static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func openAutoCount() async -> Int {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return 0 }
        let store = Store()
        guard (try? await store.requestAccess()) != nil else { return 0 }
        let open = await store.reminders(in: nil)
        return open.filter { reminder in
            guard !reminder.isCompleted else { return false }
            return Tags.parse(reminder.title ?? "").tags.contains { $0.lowercased() == "auto" }
        }.count
    }
}
