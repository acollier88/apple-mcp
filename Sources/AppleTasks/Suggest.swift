import ArgumentParser
import Contacts
import EventKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// IDEAS #41: proactive suggestions. Feed the week's signals — calendar,
// upcoming birthdays, stale tasks, recent agent activity — to the on-device
// model (same harness as #27 local triage) and emit PROPOSED items only.
// Nothing is ever created: judgment in the model, application by a human
// (or an explicit later command). Same architecture rule as triage.

struct SuggestionOut: Codable {
    /// "task" (to-do worth creating), "event" (calendar block worth adding),
    /// "drop" (stale task the human should drop or renew).
    let kind: String
    let title: String
    let reason: String
    let due: String?
}

struct SuggestOut: Codable {
    let generatedAt: String
    let inputs: Inputs
    let suggestions: [SuggestionOut]

    struct Inputs: Codable {
        let events: Int
        let birthdays: Int
        let staleTasks: Int
        let auditActions: Int
        /// Present when the birthday feed was skipped or failed.
        let contactsNote: String?
    }
}

struct Suggest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        Propose (never create) tasks/events from the week's signals — \
        calendar, birthdays, stale tasks, agent activity — via the on-device \
        model. Output is proposals only; nothing is applied.
        """
    )

    @Option(help: "Calendar look-ahead in days (default 7).")
    var days: Int = 7

    @Option(name: .customLong("stale-weeks"),
            help: "Open [read]/claimed/overdue tasks older than this count as stale (default 4).")
    var staleWeeks: Int = 4

    @Option(name: .customLong("max"), help: "Suggestion cap (default 8).")
    var maxSuggestions: Int = 8

    @Flag(name: .customLong("no-contacts"), help: "Skip the birthday feed (no Contacts prompt).")
    var noContacts = false

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        try await store.requestEventAccess()

        let (lines, inputs) = try await Suggest.gather(
            store: store, days: days, staleWeeks: staleWeeks, includeContacts: !noContacts)
        let suggestions = try await SuggestClassifier.propose(
            context: lines, max: maxSuggestions)

        emit(SuggestOut(generatedAt: ISO8601DateFormatter().string(from: Date()),
                        inputs: inputs, suggestions: suggestions))
    }

    // MARK: - signal gathering (all reads; shared with digest --suggest)

    static func gather(store: Store, days: Int, staleWeeks: Int,
                       includeContacts: Bool) async throws -> ([String], SuggestOut.Inputs) {
        var lines: [String] = []
        let now = Date()
        let calendar = Calendar.current

        // Calendar look-ahead.
        let events = store.events(from: now, to: now.addingTimeInterval(TimeInterval(days) * 86_400),
                                  calendars: nil).map(EventOut.init)
        for e in events.prefix(40) {
            var line = "EVENT \(e.start ?? "?") \(e.title)"
            if let location = e.location, !location.isEmpty { line += " @ \(location)" }
            lines.append(line)
        }

        // Upcoming birthdays (next 14 days).
        var birthdayCount = 0
        var contactsNote: String?
        if includeContacts {
            do {
                let contacts = try await ContactsAccess.request()
                let request = CNContactFetchRequest(keysToFetch: [
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactBirthdayKey as CNKeyDescriptor,
                ])
                var found: [(String, String)] = []
                try contacts.enumerateContacts(with: request) { contact, _ in
                    guard let b = contact.birthday, let month = b.month, let day = b.day else { return }
                    var next = DateComponents()
                    next.month = month
                    next.day = day
                    guard let occurrence = calendar.nextDate(after: now.addingTimeInterval(-86_400),
                                                             matching: next,
                                                             matchingPolicy: .nextTime),
                          occurrence < now.addingTimeInterval(14 * 86_400) else { return }
                    let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "someone"
                    found.append((Dates.format(occurrence, "yyyy-MM-dd"), name))
                }
                for (date, name) in found.sorted(by: { $0.0 < $1.0 }).prefix(10) {
                    lines.append("BIRTHDAY \(date) \(name)")
                    birthdayCount += 1
                }
            } catch {
                contactsNote = "birthday feed unavailable: \(error.localizedDescription)"
            }
        } else {
            contactsNote = "birthday feed skipped (--no-contacts)"
        }

        // Stale open work: [read] saves, any Mac's claim tags, or long-overdue.
        let staleCutoff = now.addingTimeInterval(-TimeInterval(staleWeeks) * 7 * 86_400)
        let open = await store.reminders(in: nil).filter { !$0.isCompleted }
        var staleCount = 0
        for reminder in open {
            let parsed = Tags.parse(reminder.title ?? "")
            let flagged = parsed.tags.contains {
                $0.lowercased() == "read" || ClaimTags.isDispatched($0) || ClaimTags.isFailed($0)
            }
            let overdue = reminder.dueDateComponents.flatMap(calendar.date(from:))
                .map { $0 < staleCutoff } ?? false
            let old = (reminder.creationDate ?? now) < staleCutoff
            guard (flagged && old) || overdue, staleCount < 30 else { continue }
            let age = Int(now.timeIntervalSince(reminder.creationDate ?? now) / 86_400)
            lines.append("STALE-TASK [\(parsed.tags.joined(separator: ","))] \(parsed.title) "
                + "(list \(reminder.calendar?.title ?? "?"), \(age)d old"
                + (overdue ? ", overdue" : "") + ")")
            staleCount += 1
        }

        // Agent activity pulse (last 24h, counts only — no bodies).
        let sinceISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400))
        let audit = AuditDB.shared.auditRows(since: sinceISO, taskId: nil, caller: nil, limit: 500)
        if !audit.isEmpty {
            var byCommand: [String: Int] = [:]
            for row in audit { byCommand[row.command, default: 0] += 1 }
            let summary = byCommand.sorted { $0.value > $1.value }
                .map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
            lines.append("ACTIVITY last 24h: \(summary)")
        }

        let inputs = SuggestOut.Inputs(events: events.count, birthdays: birthdayCount,
                                       staleTasks: staleCount, auditActions: audit.count,
                                       contactsNote: contactsNote)
        return (lines, inputs)
    }
}

enum SuggestClassifier {
    static func propose(context: [String], max maxItems: Int) async throws -> [SuggestionOut] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw AppleTasksError.saveFailed("suggest needs macOS 26+ (FoundationModels)")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw AppleTasksError.saveFailed(
                "on-device model \(LocalClassifier.status()) — check Apple Intelligence in System Settings")
        }
        guard !context.isEmpty else { return [] }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
        You are a proactive personal assistant reviewing someone's upcoming week. \
        From the signal lines provided, propose a SHORT list of genuinely helpful \
        suggestions. Kinds: "task" — a to-do worth creating; "event" — a calendar \
        block worth adding (e.g. travel time before a distant appointment); "drop" \
        — an existing STALE-TASK the person should probably drop or recommit to. \
        Normally worth raising: a BIRTHDAY in the next few days (propose a wish/\
        call/gift task due that date), an EVENT that plainly needs preparation or \
        travel, any STALE-TASK (propose dropping or recommitting). Skip routine \
        recurring events. Do not invent items with no supporting signal line. \
        Today is \(Dates.format(Date(), "yyyy-MM-dd EEEE")).
        """)
        let decision = try await session.respond(to: context.joined(separator: "\n"),
                                                 generating: SuggestionList.self).content
        return decision.items.prefix(maxItems).map {
            SuggestionOut(kind: $0.kind, title: $0.title, reason: $0.reason, due: $0.due)
        }
        #else
        throw AppleTasksError.saveFailed("suggest not compiled in (SDK lacks FoundationModels)")
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct SuggestionList {
    @Guide(description: "Helpful suggestions; empty when nothing is worth raising")
    var items: [SuggestionDecision]
}

@available(macOS 26.0, *)
@Generable
private struct SuggestionDecision {
    @Guide(description: "\"task\" to propose a to-do, \"event\" to propose a calendar block, \"drop\" to propose dropping a stale task",
           .anyOf(["task", "event", "drop"]))
    var kind: String
    @Guide(description: "Short imperative title for the proposed item")
    var title: String
    @Guide(description: "One sentence: why this is worth raising, citing the signal")
    var reason: String
    @Guide(description: "Due/start as \"yyyy-MM-dd\" or \"yyyy-MM-dd HH:mm\" when date-bound; omit otherwise")
    var due: String?
}
#endif
