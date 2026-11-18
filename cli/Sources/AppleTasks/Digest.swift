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
    let pendingReview: [PendingReviewItem]
    let auditActions: Int
    let auditByCommand: [String: Int]
    let dueToday: [TaskOut]
    let events: [EventOut]
    var noteCreated: String?
    var pushed: Bool?
    /// Open proposable findings, muted detectors excluded (#53).
    var proposals: [ProposalsInbox.Item]?
    /// --suggest only (IDEAS #41): proposals from the on-device model.
    var suggestions: [SuggestionOut]?
    var suggestError: String?
    /// True when this run sent the pending-review notification (banner + ntfy).
    /// False when the same ledger ids and branches were already announced.
    var pendingReviewNotified: Bool? = nil
    /// Tasks whose countable failures since the last success exceed maxRetries.
    var retriesExhausted: [String] = []

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
        as a new Apple Note; --push also sends it to the configured ntfy topic. \
        Pending-review branches are listed with age. A notification fires when \
        that set changes and stays quiet while the same ledger rows and \
        branches are unchanged.
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
        let pendingReview = PendingReview.items()

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
                            dispatches: dispatches, pendingReview: pendingReview,
                            auditActions: audit.count, auditByCommand: byCommand,
                            dueToday: dueToday, events: events,
                            noteCreated: nil, pushed: nil,
                            proposals: ProposalsInbox.list().proposals)
        if let maxRetries = (try? AgentsConfig.load())?.maxRetries, maxRetries > 0 {
            out.retriesExhausted = AuditDB.shared.retriesExhausted(maxRetries: maxRetries)
                .map { "\($0.taskId) (\($0.count) since last success)" }
        }

        // Suggestions are best-effort: an unavailable model annotates the
        // digest instead of failing the 7am run.
        if suggest {
            do {
                try await store.requestEventAccess()
                let (lines, _) = try await Suggest.gather(store: store, days: 7, staleWeeks: 4,
                                                          includeContacts: true)
                let suggestions = try await SuggestClassifier.propose(context: lines, max: 8)
                out.suggestions = suggestions
                let settings = (try? AgentsConfig.load())?.doctor?.detectors
                if Findings.enabled(ProposalsInbox.modelSnapshot, settings) {
                    ProposalsInbox.rememberSuggestions(
                        suggestions, lane: settings?.lanes?[ProposalsInbox.modelSnapshot])
                }
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
        out.pendingReviewNotified = await PendingReview.notifyIfChanged(
            items: pendingReview, db: .shared)
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
        var text = "\(d.dispatches.count) dispatches (\(ok) ok, \(bad) not), "
            + "\(d.auditActions) agent actions, \(d.dueToday.count) due today, "
            + "\(d.events.count) events"
        if !d.pendingReview.isEmpty {
            text += ", \(d.pendingReview.count) awaiting review"
            if let oldest = oldestPendingAge(d.pendingReview) {
                text += " (oldest \(oldest))"
            }
        }
        if !d.retriesExhausted.isEmpty {
            text += ", \(d.retriesExhausted.count) retries exhausted"
        }
        if let proposals = d.proposals, !proposals.isEmpty {
            text += ", \(proposals.count) proposals"
        }
        return text
    }

    /// Age label of the earliest `finishedAt` among pending reviews.
    static func oldestPendingAge(_ items: [PendingReviewItem]) -> String? {
        let dated: [(Date, String)] = items.compactMap { item in
            guard let finished = item.finishedAt,
                  let date = ISO8601DateFormatter().date(from: finished) else { return nil }
            return (date, item.age)
        }
        return dated.min(by: { $0.0 < $1.0 })?.1
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

        if !d.retriesExhausted.isEmpty {
            parts.append("<h2>Retries exhausted (\(d.retriesExhausted.count))</h2>")
            parts.append("<ul>" + d.retriesExhausted.map {
                "<li>\(HTML.escape($0))</li>"
            }.joined() + "</ul>")
        }

        if !d.pendingReview.isEmpty {
            parts.append("<h2>Branches awaiting review (\(d.pendingReview.count))</h2>")
            parts.append("<ul>" + d.pendingReview.map { item in
                "<li>\(HTML.escape(Self.pendingReviewLine(item)))</li>"
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

        if let proposals = d.proposals, !proposals.isEmpty {
            parts.append("<h2>Proposals (\(proposals.count))</h2>")
            parts.append("<ul>" + proposals.map { item in
                "<li><b>#\(item.id)</b> \(HTML.escape(item.detector)): \(HTML.escape(item.summary))"
                    + " — \(HTML.escape(item.evidence))</li>"
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

    static func pendingReviewLine(_ item: PendingReviewItem) -> String {
        let title: String
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            title = summary
        } else {
            title = item.taskId
        }
        // Thousands of commits "ahead" means the repo's history was rewritten
        // under the branch (weekly upstream rebase), not that the agent wrote
        // thousands of commits; say so instead of reading out a silly number.
        let ahead = item.commitsAhead > 500
            ? "stale — base history rewritten"
            : "\(item.commitsAhead) commit\(item.commitsAhead == 1 ? "" : "s")"
        return "#\(item.id) \(item.agent) — \(title) — \(item.age) — \(ahead): \(item.commits.first ?? "")"
    }
}
