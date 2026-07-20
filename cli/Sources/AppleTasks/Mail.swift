import ArgumentParser
import Foundation

struct MailHeaderOut: Codable {
    let id: String
    let subject: String
    let from: String
    let received: String
    let read: Bool
}

struct MailMessageOut: Codable {
    let id: String
    let subject: String
    let from: String
    let received: String
    let read: Bool
    let body: String
}

struct Mail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read Mail.app inbox (read-only; via Apple Events).",
        subcommands: [MailScan.self, MailShow.self],
        defaultSubcommand: MailScan.self
    )
}

struct MailScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "List inbox message headers received since a timestamp (default: last 24h). Headers only; use 'mail show' for a body."
    )

    @Option(help: "yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601 (default: 24h ago).")
    var since: String?

    @Option(help: "Maximum messages to return (default 50, newest first).")
    var limit: Int = 50

    private static let script = """
    function run(argv) {
        const since = new Date(Number(argv[0]));
        const limit = Number(argv[1]);
        const Mail = Application('Mail');
        const matched = Mail.inbox.messages.whose({ dateReceived: { _greaterThan: since } });
        const ids = matched.id();
        const subjects = matched.subject();
        const senders = matched.sender();
        const dates = matched.dateReceived();
        const readFlags = matched.readStatus();
        const rows = [];
        for (let i = 0; i < ids.length; i++) {
            rows.push({
                id: String(ids[i]),
                subject: subjects[i] || "",
                from: senders[i] || "",
                received: dates[i].toISOString(),
                read: !!readFlags[i],
            });
        }
        rows.sort((a, b) => b.received.localeCompare(a.received));
        return JSON.stringify(rows.slice(0, limit));
    }
    """

    func run() async throws {
        let sinceDate = try since.map { try Dates.parseDateTime($0).date }
            ?? Date().addingTimeInterval(-86_400)
        let sinceMs = String(Int(sinceDate.timeIntervalSince1970 * 1000))
        let raw = try OSA.runJXA(Self.script, args: [sinceMs, String(limit)])
        let headers = try JSONDecoder().decode([MailHeaderOut].self, from: Data(raw.utf8))
        emit(headers)
    }
}

struct MailShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one inbox message including its plain-text body."
    )

    @Argument(help: "Message id from 'mail scan'.")
    var id: String

    @Option(name: .customLong("max-chars"), help: "Truncate the body to this many characters (default 4000).")
    var maxChars: Int = 4000

    private static let script = """
    function run(argv) {
        const id = Number(argv[0]);
        const Mail = Application('Mail');
        const matched = Mail.inbox.messages.whose({ id: id });
        if (matched.length === 0) return "";
        const m = matched[0];
        return JSON.stringify({
            id: String(m.id()),
            subject: m.subject() || "",
            from: m.sender() || "",
            received: m.dateReceived().toISOString(),
            read: !!m.readStatus(),
            body: m.content() || "",
        });
    }
    """

    func run() async throws {
        let raw = try OSA.runJXA(Self.script, args: [id])
        guard !raw.isEmpty else { throw AppleTasksError.taskNotFound(id) }
        var message = try JSONDecoder().decode(MailMessageOut.self, from: Data(raw.utf8))
        message = MailMessageOut(
            id: message.id, subject: message.subject, from: message.from,
            received: message.received, read: message.read,
            body: String(message.body.prefix(maxChars))
        )
        emit(message)
    }
}
