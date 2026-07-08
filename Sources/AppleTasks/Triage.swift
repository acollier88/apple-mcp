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

    @Option(name: .customLong("agent"), help: "Agent tag in agents.json to classify with (default: triage).")
    var agentTag: String = "triage"

    @Flag(help: "Apply the classifications (default is a dry run that only reports).")
    var apply = false

    struct Classification: Codable {
        let id: String
        let kind: String          // "agent" | "personal"
        let tags: [String]?
        let list: String?         // target plan list for agent work (optional)
    }

    struct TriageResult: Codable {
        let inbox: String
        let untaggedCount: Int
        let applied: Bool
        let actions: [Action]
        struct Action: Codable {
            let id: String
            let title: String
            let kind: String
            let addedTags: [String]
            let movedTo: String?
            let note: String?
        }
    }

    func run() async throws {
        let store = Store()
        try await store.requestAccess()

        let inboxCal = try store.calendar(named: inbox)
        let untagged = (await store.reminders(in: [inboxCal]))
            .filter { !$0.isCompleted && Tags.parse($0.title ?? "").tags.isEmpty }

        guard !untagged.isEmpty else {
            emit(TriageResult(inbox: inbox, untaggedCount: 0, applied: false, actions: []))
            return
        }

        // Available plan lists (routing targets) — everything except the inbox.
        let planLists = store.ek.calendars(for: .reminder)
            .map(\.title)
            .filter { $0.caseInsensitiveCompare(inbox) != .orderedSame }

        let config = try AgentsConfig.load()
        guard let agent = config.agents[agentTag.lowercased()] else {
            throw AppleTasksError.saveFailed(
                "no '\(agentTag)' agent in agents.json; add one, e.g. "
                + "{\"command\": [\"agy\", \"-p\", \"{prompt}\", \"--model\", \"Gemini 3.5 Flash (Medium)\"]}")
        }

        let items = untagged.map { r -> [String: String] in
            let parsed = Tags.parse(r.title ?? "")
            return ["id": r.calendarItemExternalIdentifier ?? r.calendarItemIdentifier,
                    "title": parsed.title,
                    "notes": (r.notes ?? "").prefix(300).description]
        }
        let prompt = Self.prompt(items: items, agents: config.agents.keys.filter { $0 != agentTag.lowercased() },
                                 workdirs: Array(config.workdirs?.keys ?? [:].keys), planLists: planLists)

        let argv = agent.command.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
        let raw = try Self.runAgent(argv, timeoutMinutes: agent.timeoutMinutes ?? 5)
        let classifications = try Self.parseClassifications(raw)
        let byId = Dictionary(classifications.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var actions: [TriageResult.Action] = []
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
                reminder.title = Tags.compose(tags: addTags, title: parsed.title)
                if let moveTo { reminder.calendar = try store.calendar(named: moveTo) }
                try store.save(reminder)
                _ = NativeTags.mirror(tags: addTags, externalId: reminder.calendarItemExternalIdentifier)
                AuditDB.shared.record(command: "triage", taskId: id, list: moveTo ?? inbox,
                                      detail: "[\(addTags.joined(separator: "]["))] \(parsed.title)")
            }
            actions.append(.init(id: id, title: parsed.title, kind: c.kind,
                                 addedTags: addTags, movedTo: moveTo, note: nil))
        }

        emit(TriageResult(inbox: inbox, untaggedCount: untagged.count, applied: apply, actions: actions))
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

    static func runAgent(_ argv: [String], timeoutMinutes: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
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
    static func parseClassifications(_ raw: String) throws -> [Classification] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else {
            throw AppleTasksError.saveFailed("triage agent returned no JSON array:\n\(raw.prefix(200))")
        }
        let json = String(raw[start...end])
        return try JSONDecoder().decode([Classification].self, from: Data(json.utf8))
    }
}
