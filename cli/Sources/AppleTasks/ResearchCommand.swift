import ArgumentParser
import EventKit
import Foundation

struct Research: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research",
        abstract: """
        When budget is green, quiet hours are in effect, and a dispatch slot \
        is free, record proposals from ledger patterns. They land in the \
        same inbox as every other proposal: review them with \
        `apple-tasks proposals list | accept | dismiss`. Nothing is \
        dispatched, and an accepted research proposal gets no [auto] tag.
        """,
        subcommands: [ResearchRun.self],
        defaultSubcommand: ResearchRun.self
    )
}

struct ResearchOut: Codable {
    let ran: Bool
    let reason: String?
    let dryRun: Bool
    let recorded: [ResearchDetectors.Proposal]
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
        let budget = ResearchDetectors.spareBudget(BudgetBandwidth.load())
        let quiet = ResearchDetectors.quietState(NotifyConfig.load()?.quietHours)
        let running = AuditDB.shared.dispatchRows(status: "running", limit: 100).count
        let cap = config?.maxConcurrent ?? 1
        if let reason = ResearchDetectors.gate(budget: budget, quiet: quiet, running: running, maxConcurrent: cap) {
            emit(ResearchOut(ran: false, reason: reason, dryRun: dryRun, recorded: [], skipped: []))
            return
        }
        let runs = AuditDB.shared.dispatchRows(status: nil, limit: 200).map {
            ResearchDetectors.Run(id: $0.id, agent: $0.agent, status: $0.status)
        }
        let last = AuditDB.shared.dispatchRows(status: nil, limit: 1).first
        let lastAt = last.flatMap { ResearchClock.date($0.startedAt) }
        let openAuto = await ResearchClock.openAutoCount()
        let found = ResearchDetectors.candidates(runs: runs, openAutoCount: openAuto, lastDispatchAt: lastAt, now: Date())
        var recorded: [ResearchDetectors.Proposal] = []
        var skipped: [String] = []
        for proposal in found {
            // Same store and rules as every other proposal (#53): a dismissed
            // proposal stays quiet until its evidence changes.
            let stored = AuditDB.shared.finding(fingerprint: proposal.fingerprint).map {
                ResearchDetectors.Stored(evidenceHash: $0.evidenceHash,
                                         status: $0.state == "open" ? "proposed" : $0.state)
            }
            switch ResearchDetectors.decide(proposal, stored: stored) {
            case .skip:
                skipped.append(proposal.fingerprint)
            case .record, .reopen:
                if dryRun {
                    recorded.append(proposal)
                    continue
                }
                let result = ProposalsInbox.remember(
                    detector: proposal.detector, kind: "task", title: proposal.title,
                    evidence: proposal.evidence, lane: nil, fingerprint: proposal.fingerprint)
                if result == "open" || result == "refresh" {
                    recorded.append(proposal)
                } else {
                    skipped.append(proposal.fingerprint)
                }
            }
        }
        emit(ResearchOut(ran: true, reason: nil, dryRun: dryRun, recorded: recorded, skipped: skipped))
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
