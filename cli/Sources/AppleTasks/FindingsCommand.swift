import ArgumentParser
import Foundation

struct FindingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "findings",
        abstract: "List detector findings doctor has recorded. Same evidence stays quiet until it changes."
    )

    @Option(name: .customLong("class"), help: "healable, proposable, or needs-human.")
    var findingClass: String?

    @Option(name: .long, help: "open, healed, accepted, dismissed, expired, or all.")
    var state: String = "open"

    func run() throws {
        let rows = AuditDB.shared.findings(
            state: state == "all" ? nil : state,
            findingClass: findingClass,
            limit: 100)
        emit(FindingsList(findings: rows))
    }
}

struct FindingsList: Codable {
    let findings: [AuditDB.FindingRow]
}
