import ArgumentParser
import EventKit
import Foundation

// IDEAS #8: morning digest. Deterministic aggregation — no model, no
// judgment calls — so it can run unattended from launchd/cron at 7am:
// what agents did (audit log), dispatch outcomes, tasks due today, and
// today's calendar. Emits JSON; --note writes it as a NEW Apple Note
// (creating notes is safe — the read-only rule is about editing existing
// bodies); --push fires the configured ntfy topic.

struct NotesCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a NEW Apple Note (never edits existing notes). Body is HTML."
    )

    @Option(help: "Notes folder to create in (default: the default folder).")
    var folder: String?

    @Option(help: "Note title (rendered as the first line).")
    var title: String

    @Argument(help: "Note body as HTML (the title is prepended as <h1>).")
    var body: String

    private static let script = """
    function run(argv) {
        const app = Application('Notes');
        const note = app.Note({ body: argv[0] });
        const folderName = argv[1];
        if (folderName) {
            app.folders.byName(folderName).notes.push(note);
        } else {
            app.notes.push(note);
        }
        return JSON.stringify({ id: note.id(), name: note.name() });
    }
    """

    static func create(title: String, bodyHTML: String, folder: String?) throws -> String {
        let html = "<h1>\(HTML.escape(title))</h1>\n\(bodyHTML)"
        return try OSA.runJXA(script, args: [html, folder ?? ""])
    }

    func run() async throws {
        let raw = try Self.create(title: title, bodyHTML: body, folder: folder)
        AuditDB.shared.record(command: "notes-create", taskId: nil, list: folder,
                              detail: title)
        print(raw)
    }
}

struct DigestOut: Codable {
    let since: String
    let generatedAt: String
    let dispatches: [DispatchLine]
    let auditActions: Int
    let auditByCommand: [String: Int]
    let dueToday: [TaskOut]
    let events: [EventOut]
    var noteCreated: String?
    var pushed: Bool?
    /// --suggest only (IDEAS #41): proposals from the on-device model.
    var suggestions: [SuggestionOut]?
    var suggestError: String?

    struct DispatchLine: Codable {
        let id: Int
        let agent: String
        let status: String
        let summary: String?
        let taskId: String
    }
}

struct Digest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Morning digest: agent activity since yesterday, dispatch outcomes, \
        tasks due today, today's calendar. Emits JSON; --note also writes it \
        as a new Apple Note; --push also sends it to the configured ntfy topic.
        """
    )

    @Option(help: "Look-back start: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601 (default: 24h ago).")
    var since: String?

    @Flag(help: "Write the digest as a new Apple Note.")
    var note = false

    @Option(name: .customLong("note-folder"), help: "Notes folder for --note.")
    var noteFolder: String?

    @Flag(help: "Send a short summary to the configured ntfy topic (notify.json).")
    var push = false

    @Flag(help: "Append proposals from the on-device model (IDEAS #41; never auto-created).")
    var suggest = false

    func run() async throws {
        let sinceDate = try since.map { try Dates.parseDateTime($0).date }
            ?? Date().addingTimeInterval(-86_400)
        let iso = ISO8601DateFormatter()
        let sinceISO = iso.string(from: sinceDate)

        let store = Store()
        try await store.requestAccess()

        // Agent activity + dispatch outcomes since the watermark.
        let audit = AuditDB.shared.auditRows(since: sinceISO, taskId: nil, caller: nil, limit: 500)
        var byCommand: [String: Int] = [:]
        for row in audit { byCommand[row.command, default: 0] += 1 }
        let dispatches = AuditDB.shared.dispatchRows(status: nil, limit: 100)
            .filter { $0.startedAt >= sinceISO }
            .map { DigestOut.DispatchLine(id: $0.id, agent: $0.agent, status: $0.status,
                                          summary: $0.summary, taskId: $0.taskId) }

        // Due today (incl. overdue) + today's calendar.
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = startOfDay.addingTimeInterval(86_400)
        let dueToday = (await store.reminders(in: nil))
            .filter { r in
                guard !r.isCompleted, let comps = r.dueDateComponents,
                      let due = calendar.date(from: comps) else { return false }
                return due < endOfDay
            }
            .map(TaskOut.init)
        let events = store.events(from: startOfDay, to: endOfDay, calendars: nil)
            .map(EventOut.init)

        var out = DigestOut(since: sinceISO, generatedAt: iso.string(from: Date()),
                            dispatches: dispatches, auditActions: audit.count,
                            auditByCommand: byCommand, dueToday: dueToday, events: events,
                            noteCreated: nil, pushed: nil)

        // Suggestions are best-effort: an unavailable model annotates the
        // digest instead of failing the 7am run.
        if suggest {
            do {
                try await store.requestEventAccess()
                let (lines, _) = try await Suggest.gather(store: store, days: 7, staleWeeks: 4,
                                                          includeContacts: true)
                out.suggestions = try await SuggestClassifier.propose(context: lines, max: 8)
            } catch {
                out.suggestError = (error as? AppleTasksError)?.description ?? error.localizedDescription
            }
        }

        if note {
            let raw = try NotesCreate.create(title: Self.noteTitle(),
                                             bodyHTML: Self.html(out), folder: noteFolder)
            struct Created: Codable { let id: String }
            out.noteCreated = (try? JSONDecoder().decode(Created.self, from: Data(raw.utf8)))?.id ?? "created"
            AuditDB.shared.record(command: "digest", taskId: nil, list: noteFolder,
                                  detail: "note: \(Self.noteTitle())")
        }
        if push {
            out.pushed = await Notifier.push(title: Self.noteTitle(), body: Self.pushSummary(out))
        }
        emit(out)
    }

    // MARK: - rendering

    static func noteTitle(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d"
        return "Agent digest — \(fmt.string(from: now))"
    }

    static func pushSummary(_ d: DigestOut) -> String {
        let ok = d.dispatches.filter { $0.status == "succeeded" }.count
        let bad = d.dispatches.count - ok
        return "\(d.dispatches.count) dispatches (\(ok) ok, \(bad) not), "
            + "\(d.auditActions) agent actions, \(d.dueToday.count) due today, "
            + "\(d.events.count) events"
    }

    static func html(_ d: DigestOut) -> String {
        var parts: [String] = []

        parts.append("<h2>Dispatches (\(d.dispatches.count))</h2>")
        if d.dispatches.isEmpty {
            parts.append("<p>No agent runs.</p>")
        } else {
            parts.append("<ul>" + d.dispatches.map { line in
                "<li><b>#\(line.id)</b> \(HTML.escape(line.agent)) — \(HTML.escape(line.status))"
                    + (line.summary.map { ": \(HTML.escape(String($0.prefix(140))))" } ?? "")
                    + "</li>"
            }.joined() + "</ul>")
        }

        parts.append("<h2>Agent activity (\(d.auditActions) actions)</h2>")
        if d.auditByCommand.isEmpty {
            parts.append("<p>None.</p>")
        } else {
            parts.append("<ul>" + d.auditByCommand.sorted { $0.value > $1.value }.map {
                "<li>\(HTML.escape($0.key)) × \($0.value)</li>"
            }.joined() + "</ul>")
        }

        parts.append("<h2>Due today (\(d.dueToday.count))</h2>")
        if d.dueToday.isEmpty {
            parts.append("<p>Nothing due.</p>")
        } else {
            parts.append("<ul>" + d.dueToday.map { t in
                let title = HTML.escape(t.title)
                // Only link http(s) — a task URL is agent/classifier-written,
                // so other schemes (javascript:, file:) don't get an <a>.
                let safeURL = t.url.flatMap { url in
                    let lower = url.lowercased()
                    return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? url : nil
                }
                let linked = safeURL.map { "<a href=\"\(HTML.escape($0))\">\(title)</a>" } ?? title
                return "<li>\(linked) (\(HTML.escape(t.list))\(t.due.map { ", due \(HTML.escape($0))" } ?? ""))</li>"
            }.joined() + "</ul>")
        }

        parts.append("<h2>Today's calendar (\(d.events.count))</h2>")
        if d.events.isEmpty {
            parts.append("<p>Clear.</p>")
        } else {
            parts.append("<ul>" + d.events.map { e in
                let when = e.allDay ? "all day" : String((e.start ?? "").dropFirst(11).prefix(5))
                return "<li>\(HTML.escape(when)) — \(HTML.escape(e.title))"
                    + (e.location.map { " @ \(HTML.escape($0))" } ?? "") + "</li>"
            }.joined() + "</ul>")
        }

        if let suggestions = d.suggestions {
            parts.append("<h2>Suggestions (\(suggestions.count))</h2>")
            if suggestions.isEmpty {
                parts.append("<p>Nothing to raise.</p>")
            } else {
                parts.append("<ul>" + suggestions.map { s in
                    "<li><b>\(HTML.escape(s.kind))</b>: \(HTML.escape(s.title))"
                        + (s.due.map { " (\(HTML.escape($0)))" } ?? "")
                        + " — \(HTML.escape(s.reason))</li>"
                }.joined() + "</ul>")
            }
        }

        return parts.joined(separator: "\n")
    }
}
