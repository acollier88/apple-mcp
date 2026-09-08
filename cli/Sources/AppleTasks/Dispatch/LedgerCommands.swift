import ArgumentParser
import Foundation

// MARK: - log / dispatches (read the machine-side memory)

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the audit log: what was done, when, by which caller."
    )

    @Option(help: "Only entries at/after this ISO8601 timestamp or yyyy-MM-dd.")
    var since: String?

    @Option(name: .customLong("task"), help: "Only entries for this task id.")
    var taskId: String?

    @Option(help: "Filter by caller substring (mcp, app, dispatcher, zsh...).")
    var caller: String?

    @Option(help: "Max rows (default 50, newest first).")
    var limit: Int = 50

    func run() async throws {
        emit(AuditDB.shared.auditRows(since: since, taskId: taskId, caller: caller, limit: limit))
    }
}

struct Dispatches: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the dispatch ledger (agent runs and their outcomes)."
    )

    @Option(help: "Filter: running | succeeded | failed.")
    var status: String?

    @Option(help: "Max rows (default 50, newest first).")
    var limit: Int = 50

    func run() async throws {
        emit(AuditDB.shared.dispatchRows(status: status, limit: limit))
    }
}
