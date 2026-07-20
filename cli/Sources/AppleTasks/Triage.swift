import ArgumentParser
import EventKit
import Foundation

// One-shot inbox triage: spawn a cheap classifier agent over untagged inbox
// items, then apply the routing decisions here (the CLI mutates, the agent
// only judges). No loop, no worktree — this is pure classification.

struct Triage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Classify and route untagged inbox reminders in one shot. Spawns the \
        configured 'triage' agent (agents.json) to classify each untagged task \
        as agent-work or personal, then applies tags/list moves. Default is a \
        dry run; pass --apply to make changes.
        """
    )

    @Option(help: "Reminders list to triage (default: Reminders).")
    var inbox: String = "Reminders"

    @Option(name: .customLong("agent"), help: "Classifier: an agents.json tag, or 'local' for the on-device Apple model (default: triage).")
    var agentTag: String = "triage"

    @Flag(help: "Apply the classifications (default is a dry run that only reports).")
    var apply = false

    @Flag(name: .customLong("notes"), help: """
    Also scan Apple Notes (shared notes-scan watermark; advanced only on \
    --apply) and turn action items into tasks/events with the source note's \
    name in the created item's notes.
    """)
    var includeNotes = false

    struct Classification: Codable {
        let id: String
        let kind: String          // "agent" | "personal"
        let tags: [String]?
        let list: String?         // target plan list for agent work (optional)
    }

    struct NoteClassification: Codable {
        let source: String?       // note name
        let kind: String          // "task" | "event" | "noise"
        let title: String
        let due: String?          // yyyy-MM-dd or 'yyyy-MM-dd HH:mm'
        let tags: [String]?
        let list: String?
    }

    struct TriageResult: Codable {
        let inbox: String
        let untaggedCount: Int
        let applied: Bool
        let actions: [Action]
        var noteActions: [NoteAction]?
        struct Action: Codable {
            let id: String
            let title: String
            let kind: String
            let addedTags: [String]
            let movedTo: String?
            let note: String?
        }
        struct NoteAction: Codable {
            let source: String
            let kind: String      // "task" | "event"
            let title: String
            let due: String?
            let tags: [String]
            let list: String?
            let note: String?     // skip/downgrade reason
        }
    }

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        emit(try await Self.triage(store: store, inbox: inbox, agentTag: agentTag, apply: apply,
                                   includeNotes: includeNotes))
    }

    /// Core triage pass, callable from the command or the dispatcher.
    static func triage(store: Store, inbox: String, agentTag: String, apply: Bool,
                       includeNotes: Bool = false) async throws -> TriageResult {
        let inboxCal = try store.calendar(named: inbox)
        // Candidates: untagged items, plus items carrying ONLY provenance
        // tags (e.g. [mail] from the mail-rule capture) — those were tagged
        // by a capture channel, not a triage, and still need routing.
        let provenanceTags: Set<String> = ["mail"]
        let untagged = (await store.reminders(in: [inboxCal]))
            .filter { r in
                guard !r.isCompleted else { return false }
                return Tags.parse(r.title ?? "").tags
                    .allSatisfy { provenanceTags.contains($0.lowercased()) }
            }

        // Available plan lists (routing targets) — everything except the inbox.
        let planLists = store.ek.calendars(for: .reminder)
            .map(\.title)
            .filter { $0.caseInsensitiveCompare(inbox) != .orderedSame }

        let config = try AgentsConfig.load()
        // Routing targets exclude classifier lanes — never route work TO a classifier.
        let classifierTags: Set<String> = [agentTag.lowercased(), "triage", LocalClassifier.agentTag]
        let routingAgents = config.agents.keys.filter { !classifierTags.contains($0) }.sorted()
        let workdirs = Array(config.workdirs?.keys ?? [:].keys)
        let useLocal = agentTag.lowercased() == LocalClassifier.agentTag

        func externalAgent() throws -> (AgentsConfig.Agent, template: [String]) {
            guard let agent = config.agents[agentTag.lowercased()] else {
                throw AppleTasksError.saveFailed(
                    "no '\(agentTag)' agent in agents.json; add one, e.g. "
                    + "{\"command\": [\"agy\", \"-p\", \"{prompt}\", \"--model\", \"Gemini 3.5 Flash (Medium)\"]}"
                    + " or a BYOM lane {\"llm\": {\"endpoint\": ..., \"model\": ...}}"
                    + " — or use --agent local for the on-device model")
            }
            guard let template = agent.commandTemplate(tag: agentTag.lowercased()) else {
                throw AppleTasksError.saveFailed(
                    "agent '\(agentTag)' has neither \"command\" nor \"llm\" in agents.json")
            }
            return (agent, template)
        }

        var actions: [TriageResult.Action] = []
        if untagged.isEmpty {
            // nothing to classify in the inbox; notes may still have work
        } else {

        let items = untagged.map { r -> [String: String] in
            let parsed = Tags.parse(r.title ?? "")
            return ["id": r.calendarItemExternalIdentifier ?? r.calendarItemIdentifier,
                    "title": parsed.title,
                    "notes": (r.notes ?? "").prefix(300).description]
        }

        let classifications: [Classification]
        if useLocal {
            // IDEAS #27: on-device SystemLanguageModel, no subprocess.
            classifications = try await LocalClassifier.classify(
                items: items, agents: routingAgents, workdirs: workdirs, planLists: planLists)
        } else {
            let (agent, template) = try externalAgent()
            let prompt = Self.prompt(items: items, agents: routingAgents,
                                     workdirs: workdirs, planLists: planLists)
            let argv = template.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
            let raw = try Self.runAgent(argv, timeoutMinutes: agent.timeoutMinutes ?? 5, env: agent.env)
            classifications = try Self.parseJSONArray(raw)
        }
        let byId = Dictionary(classifications.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for reminder in untagged {
            let id = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
            let parsed = Tags.parse(reminder.title ?? "")
            guard let c = byId[id] else {
                actions.append(.init(id: id, title: parsed.title, kind: "skipped",
                                     addedTags: [], movedTo: nil, note: "agent returned no classification"))
                continue
            }

            var addTags = (c.tags ?? []).filter { (try? Tags.validate($0)) != nil }
            if c.kind == "personal" {
                addTags = ["personal"]
            } else if !addTags.contains(where: { $0.caseInsensitiveCompare("personal") == .orderedSame }) {
                // agent work must carry at least one routing tag; fall back to a generic one
                if addTags.isEmpty { addTags = ["triage"] }
            }

            var moveTo: String?
            if c.kind == "agent", let target = c.list,
               planLists.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
                moveTo = target
            }

            if apply {
                // Provenance tags a capture channel already set (e.g. [mail]) survive.
                let merged = parsed.tags + addTags.filter { new in
                    !parsed.tags.contains { $0.caseInsensitiveCompare(new) == .orderedSame }
                }
                reminder.title = Tags.compose(tags: merged, title: parsed.title)
                if let moveTo { reminder.calendar = try store.calendar(named: moveTo) }
                try store.save(reminder)
                _ = NativeTags.mirror(tags: merged, externalId: reminder.calendarItemExternalIdentifier)
                AuditDB.shared.record(command: "triage", taskId: id, list: moveTo ?? inbox,
                                      detail: "[\(merged.joined(separator: "]["))] \(parsed.title)")
            }
            actions.append(.init(id: id, title: parsed.title, kind: c.kind,
                                 addedTags: addTags, movedTo: moveTo, note: nil))
        }

        } // untagged classification

        // IDEAS #34: notes → tasks/events through the same judge-then-apply
        // pipeline. The shared notes-scan watermark is the dedupe; it only
        // advances on --apply so dry runs can be repeated.
        var noteActions: [TriageResult.NoteAction]?
        if includeNotes {
            let scanStart = Date()
            let notes = try NotesScan.scan(folder: nil,
                                           since: NotesScan.watermarkDate(asOf: scanStart),
                                           maxChars: 2000)
            var collected: [TriageResult.NoteAction] = []
            if !notes.isEmpty {
                try await store.requestEventAccess()
                let noteItems = notes.map { ["name": $0.name, "body": $0.body] }
                let decisions: [NoteClassification]
                if useLocal {
                    decisions = try await LocalClassifier.classifyNotes(
                        notes: noteItems, agents: routingAgents,
                        workdirs: workdirs, planLists: planLists)
                } else {
                    let (agent, template) = try externalAgent()
                    let prompt = Self.notesPrompt(notes: noteItems, agents: routingAgents,
                                                  workdirs: workdirs, planLists: planLists)
                    let argv = template.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
                    let raw = try Self.runAgent(argv, timeoutMinutes: agent.timeoutMinutes ?? 5, env: agent.env)
                    decisions = try Self.parseJSONArray(raw)
                }
                collected = try Self.applyNoteDecisions(decisions, store: store, apply: apply,
                                                        planLists: planLists, inbox: inbox)
            }
            noteActions = collected
            if apply { try NotesScan.advanceWatermark(to: scanStart) }
        }

        return TriageResult(inbox: inbox, untaggedCount: untagged.count, applied: apply,
                            actions: actions, noteActions: noteActions)
    }

    /// Create the classified note items — tasks in a plan list (or the
    /// inbox), events on the default calendar — with the source note's name
    /// in the created item's notes for provenance.
    static func applyNoteDecisions(_ decisions: [NoteClassification], store: Store, apply: Bool,
                                   planLists: [String], inbox: String) throws -> [TriageResult.NoteAction] {
        var out: [TriageResult.NoteAction] = []
        var seenTitles = Set<String>()
        for decision in decisions {
            var kind = decision.kind.lowercased()
            guard kind != "noise" else { continue }
            let title = decision.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seenTitles.insert(title.lowercased()).inserted else { continue }
            let source = decision.source ?? "note"
            let tags = (decision.tags ?? []).filter { (try? Tags.validate($0)) != nil }
            let due = decision.due.flatMap { try? Dates.parseDateTime($0) }

            var downgrade: String?
            if kind == "event" && due == nil {
                kind = "task" // an event needs a parseable date
                downgrade = "no parseable date — created as task"
            }

            if kind == "event", let due {
                if apply {
                    guard let calendar = store.ek.defaultCalendarForNewEvents else {
                        out.append(.init(source: source, kind: "event", title: title,
                                         due: decision.due, tags: tags, list: nil,
                                         note: "skipped: no default calendar"))
                        continue
                    }
                    let event = EKEvent(eventStore: store.ek)
                    event.calendar = calendar
                    event.title = Tags.compose(tags: tags, title: title)
                    event.startDate = due.date
                    if due.dateOnly {
                        event.isAllDay = true
                        event.endDate = due.date
                    } else {
                        event.endDate = due.date.addingTimeInterval(3600)
                    }
                    event.notes = "from note: \(source)"
                    try store.save(event)
                    AuditDB.shared.record(command: "triage-note", taskId: event.eventIdentifier,
                                          list: calendar.title, detail: "[event] \(title)")
                }
                out.append(.init(source: source, kind: "event", title: title,
                                 due: decision.due, tags: tags, list: nil, note: nil))
            } else {
                let listName = decision.list.flatMap { target in
                    planLists.first { $0.caseInsensitiveCompare(target) == .orderedSame }
                } ?? inbox
                if apply {
                    let reminder = EKReminder(eventStore: store.ek)
                    reminder.calendar = try store.calendar(named: listName)
                    reminder.title = Tags.compose(tags: tags, title: title)
                    if let due {
                        var components: Set<Calendar.Component> = [.year, .month, .day]
                        if !due.dateOnly { components.formUnion([.hour, .minute]) }
                        reminder.dueDateComponents = Calendar.current.dateComponents(components, from: due.date)
                    }
                    reminder.notes = "from note: \(source)"
                    try store.save(reminder)
                    _ = NativeTags.mirror(tags: tags, externalId: reminder.calendarItemExternalIdentifier)
                    AuditDB.shared.record(command: "triage-note",
                                          taskId: reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier,
                                          list: listName, detail: "[task] \(title)")
                }
                out.append(.init(source: source, kind: "task", title: title,
                                 due: decision.due, tags: tags, list: listName, note: downgrade))
            }
        }
        return out
    }

    // MARK: - prompt + agent spawn

    static func prompt(items: [[String: String]], agents: some Collection<String>,
                       workdirs: [String], planLists: [String]) -> String {
        let itemsJSON = (try? String(data: JSONSerialization.data(withJSONObject: items), encoding: .utf8)) ?? "[]"
        return """
        You are an inbox triage classifier for a task queue. Classify each item \
        as "agent" (actionable software/repo work an AI coding agent could do) or \
        "personal" (errands, appointments, finances — anything not software work).

        For "agent" items, choose tags: exactly one agent from \
        [\(agents.sorted().joined(separator: ", "))], one repo from \
        [\(workdirs.sorted().joined(separator: ", "))] if one clearly applies, and \
        pick a target plan list from [\(planLists.joined(separator: ", "))] if one fits \
        (else null). For "personal" items, tags and list are ignored.

        Output ONLY a JSON array, no prose, no markdown fences:
        [{"id": "<id>", "kind": "agent"|"personal", "tags": ["agent","repo",...], "list": "<plan list or null>"}]

        Items:
        \(itemsJSON)
        """
    }

    static func notesPrompt(notes: [[String: String]], agents: some Collection<String>,
                            workdirs: [String], planLists: [String]) -> String {
        let notesJSON = (try? String(data: JSONSerialization.data(withJSONObject: notes), encoding: .utf8)) ?? "[]"
        return """
        You extract action items from Apple Notes for a task queue. For each \
        note, emit zero or more actions. kind "event" for date/time-bound \
        items (set "due" as "yyyy-MM-dd" or "yyyy-MM-dd HH:mm"); kind "task" \
        for actionable work (for software/repo work, tags: one agent from \
        [\(agents.sorted().joined(separator: ", "))] plus a repo from \
        [\(workdirs.sorted().joined(separator: ", "))] if one clearly applies, \
        and "list" from [\(planLists.joined(separator: ", "))] if one fits). \
        Ignore journal-style content; when unsure, skip — emit nothing rather \
        than duplicates or noise.

        Output ONLY a JSON array, no prose, no markdown fences:
        [{"source": "<note name>", "kind": "task"|"event", "title": "...", \
        "due": "yyyy-MM-dd HH:mm" or null, "tags": [...], "list": "..." or null}]

        Notes:
        \(notesJSON)
        """
    }

    static func runAgent(_ argv: [String], timeoutMinutes: Int,
                         env extraEnv: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let extraEnv, !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (name, value) in extraEnv { env[name] = value }
            process.environment = env
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // A classifier agent takes no input; an inherited stdin makes some
        // CLIs (agy) block waiting on a terminal, so close it explicitly.
        process.standardInput = FileHandle.nullDevice

        // Drain the pipe on a background queue so a full buffer can't deadlock
        // the wait, and so we can enforce a hard timeout.
        var collected = Data()
        let lock = NSLock()
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.lock(); collected.append(chunk); lock.unlock()
        }

        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMinutes) * 60)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw AppleTasksError.saveFailed("triage agent timed out after \(timeoutMinutes)m")
        }
        process.waitUntilExit()
        reader.readabilityHandler = nil
        if let rest = try? reader.readToEnd() { collected.append(rest) }
        guard process.terminationStatus == 0 else {
            throw AppleTasksError.saveFailed("triage agent exited \(process.terminationStatus)")
        }
        lock.lock(); let data = collected; lock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Extract the JSON array from agent stdout (tolerating stray prose or fences).
    static func parseJSONArray<T: Decodable>(_ raw: String) throws -> [T] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else {
            throw AppleTasksError.saveFailed("triage agent returned no JSON array:\n\(raw.prefix(200))")
        }
        let json = String(raw[start...end])
        return try JSONDecoder().decode([T].self, from: Data(json.utf8))
    }
}
