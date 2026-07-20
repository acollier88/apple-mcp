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
        abstract: "Read Mail.app inbox and create drafts (via Apple Events; drafts are NEVER sent).",
        subcommands: [MailScan.self, MailShow.self, MailDraft.self],
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

// IDEAS #37: the reply half of the two-way email interface. Agents write
// their report as a DRAFT — this command has no send path at all; the
// human reviews in Mail (any device, drafts sync) and hits send.
struct MailDraft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: """
        Create a draft in Mail.app — never sends. Either a new message \
        (--to + --subject) or a reply (--reply-to <message-id>, threading \
        preserved). Body from --body or --body-file.
        """
    )

    @Option(help: "Recipient address (repeatable). Required unless --reply-to.")
    var to: [String] = []

    @Option(help: "Subject. Required for new drafts; replies default to Re: <original>.")
    var subject: String?

    @Option(help: "Body text.")
    var body: String?

    @Option(name: .customLong("body-file"), help: "Read the body from this file (for long reports).")
    var bodyFile: String?

    @Option(name: .customLong("reply-to"), help: "Draft a reply to this message: an RFC Message-ID (from a [mail] task's notes) or a numeric id from 'mail scan'.")
    var replyTo: String?

    struct Out: Codable {
        let drafted: Bool
        let mode: String        // "new" | "reply"
        let to: [String]
        let subject: String
        /// Reply mode: the id of the message being replied to.
        let inReplyTo: String?
    }

    // New draft: build an outgoing message, add recipients, save → Drafts.
    private static let newDraftScript = """
    function run(argv) {
        const [subject, content] = [argv[0], argv[1]];
        const recipients = JSON.parse(argv[2]);
        const Mail = Application('Mail');
        const msg = Mail.OutgoingMessage({ subject: subject, content: content, visible: false });
        Mail.outgoingMessages.push(msg);
        for (const addr of recipients) {
            msg.toRecipients.push(Mail.ToRecipient({ address: addr }));
        }
        msg.save();
        return JSON.stringify({ subject: subject, to: recipients });
    }
    """

    // Reply draft: locate the original (RFC message-id or numeric id), use
    // Mail's native reply so threading headers and recipients are correct,
    // then set the body and save. openingWindow:false keeps it headless.
    private static let replyDraftScript = """
    function run(argv) {
        const [rawId, content, subjectOverride] = [argv[0], argv[1], argv[2]];
        const Mail = Application('Mail');
        const cleanId = rawId.replace(/^<|>$/g, "");
        let matched = /^[0-9]+$/.test(cleanId)
            ? Mail.inbox.messages.whose({ id: Number(cleanId) })
            : Mail.inbox.messages.whose({ messageId: cleanId });
        if (matched.length === 0) return "";
        const original = matched[0];
        const draft = Mail.reply(original, { openingWindow: false });
        draft.content = content;
        if (subjectOverride) draft.subject = subjectOverride;
        draft.save();
        return JSON.stringify({
            subject: draft.subject(),
            to: draft.toRecipients.address(),
            inReplyTo: String(original.id()),
        });
    }
    """

    func run() async throws {
        var content = body
        if let bodyFile {
            let path = NSString(string: bodyFile).expandingTildeInPath
            guard let fileText = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw AppleTasksError.saveFailed("could not read --body-file \(path)")
            }
            content = fileText
        }
        guard let content, !content.isEmpty else {
            throw AppleTasksError.saveFailed("a draft needs a body: pass --body or --body-file")
        }

        struct ScriptOut: Codable {
            let subject: String
            let to: [String]
            var inReplyTo: String?
        }
        let result: ScriptOut
        if let replyTo {
            let raw = try OSA.runJXA(Self.replyDraftScript, args: [replyTo, content, subject ?? ""])
            guard !raw.isEmpty else {
                throw AppleTasksError.automationFailed(
                    "no inbox message matching '\(replyTo)' (archived/deleted messages aren't searched)")
            }
            result = try JSONDecoder().decode(ScriptOut.self, from: Data(raw.utf8))
        } else {
            guard !to.isEmpty else {
                throw AppleTasksError.saveFailed("a new draft needs --to (or use --reply-to for a reply)")
            }
            guard let subject, !subject.isEmpty else {
                throw AppleTasksError.saveFailed("a new draft needs --subject")
            }
            let recipientsJSON = String(data: try JSONEncoder().encode(to), encoding: .utf8)!
            let raw = try OSA.runJXA(Self.newDraftScript, args: [subject, content, recipientsJSON])
            result = try JSONDecoder().decode(ScriptOut.self, from: Data(raw.utf8))
        }

        let out = Out(drafted: true, mode: replyTo == nil ? "new" : "reply",
                      to: result.to, subject: result.subject, inReplyTo: result.inReplyTo)
        AuditDB.shared.record(command: "mail draft",
                              detail: "\(out.mode): \(out.subject) → \(out.to.joined(separator: ", "))")
        emit(out)
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
