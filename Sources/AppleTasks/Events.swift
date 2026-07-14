import ArgumentParser
import EventKit
import Foundation

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Calendar events (same [tag] title convention as tasks).",
        subcommands: [EventsList.self, EventsAdd.self, EventsUpdate.self, EventsDelete.self],
        defaultSubcommand: EventsList.self
    )
}

struct EventsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List events in a date range (default: today through +7 days)."
    )

    @Option(name: .customLong("calendar"), help: "Only events in this calendar.")
    var calendarName: String?

    @Option(name: [.customShort("t"), .customLong("tag")], help: "Require this tag (repeatable; AND).")
    var tags: [String] = []

    @Option(help: "Range start: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601 (default: start of today).")
    var from: String?

    @Option(help: "Range end, same formats (default: from + 7 days).")
    var to: String?

    func run() async throws {
        let store = Store()
        try await store.requestEventAccess()
        let calendars = try calendarName.map { [try store.eventCalendar(named: $0)] }

        let fromDate = try from.map { try Dates.parseDateTime($0).date }
            ?? Calendar.current.startOfDay(for: Date())
        let toDate = try to.map { parsed -> Date in
            let (date, dateOnly) = try Dates.parseDateTime(parsed)
            // A date-only end bound should include that whole day.
            return dateOnly ? date.addingTimeInterval(86_400) : date
        } ?? fromDate.addingTimeInterval(7 * 86_400)

        var events = store.events(from: fromDate, to: toDate, calendars: calendars).map(EventOut.init)
        if !tags.isEmpty {
            let wanted = Set(tags.map { $0.lowercased() })
            events = events.filter { wanted.isSubset(of: $0.tags.map { $0.lowercased() }) }
        }
        emit(events)
    }
}

struct EventsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create an event. A date-only --start makes an all-day event."
    )

    @Option(name: .customLong("calendar"), help: "Calendar to add the event to (default: system default calendar).")
    var calendarName: String?

    @Option(name: [.customShort("t"), .customLong("tag")], help: "Tag to prefix onto the title (repeatable).")
    var tags: [String] = []

    @Option(help: "Start: yyyy-MM-dd (all-day), 'yyyy-MM-dd HH:mm', or ISO8601.")
    var start: String

    @Option(help: "End, same formats. Mutually exclusive with --duration.")
    var end: String?

    @Option(help: "Duration in minutes (default 60 when --end is omitted).")
    var duration: Int?

    @Option(help: "Location string.")
    var location: String?

    @Option(help: "Notes body.")
    var notes: String?

    @Option(help: "URL to attach (use for PR/artifact links).")
    var url: String?

    @Option(help: "Repeat rule. \(Recurrence.helpText)")
    var recurrence: String?

    @Argument(help: "Event title (without tag prefix).")
    var title: String

    func run() async throws {
        for tag in tags { try Tags.validate(tag) }
        let store = Store()
        try await store.requestEventAccess()

        let event = EKEvent(eventStore: store.ek)
        if let calendarName {
            event.calendar = try store.eventCalendar(named: calendarName)
        } else if let defaultCalendar = store.ek.defaultCalendarForNewEvents {
            event.calendar = defaultCalendar
        } else {
            throw AppleTasksError.calendarNotFound("(no default calendar)")
        }

        event.title = Tags.compose(tags: tags, title: title)
        event.location = location
        event.notes = notes
        if let url { event.url = URL(string: url) }

        let (startDate, dateOnly) = try Dates.parseDateTime(start)
        event.startDate = startDate
        if dateOnly {
            event.isAllDay = true
            event.endDate = startDate
        } else if let end {
            event.endDate = try Dates.parseDateTime(end).date
        } else {
            event.endDate = startDate.addingTimeInterval(TimeInterval((duration ?? 60) * 60))
        }
        if let recurrence { event.addRecurrenceRule(try Recurrence.parse(recurrence)) }

        try store.save(event)
        let out = EventOut(event)
        AuditDB.shared.record(command: "events add", taskId: out.id, list: out.calendar, detail: out.rawTitle)
        emit(out)
    }
}

struct EventsUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an event's title, tags, times, location, notes, or calendar."
    )

    @Argument(help: "Event id.")
    var id: String

    @Option(help: "New title (tags are preserved).")
    var title: String?

    @Option(name: .customLong("add-tag"), help: "Add a tag (repeatable).")
    var addTags: [String] = []

    @Option(name: .customLong("remove-tag"), help: "Remove a tag (repeatable, case-insensitive).")
    var removeTags: [String] = []

    @Option(help: "New start: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601.")
    var start: String?

    @Option(help: "New end, same formats.")
    var end: String?

    @Option(help: "New location.")
    var location: String?

    @Option(help: "New notes body.")
    var notes: String?

    @Option(help: "Set the event URL (use for PR/artifact links).")
    var url: String?

    @Flag(name: .customLong("clear-url"), help: "Remove the event URL.")
    var clearUrl = false

    @Option(name: .customLong("calendar"), help: "Move the event to this calendar.")
    var calendarName: String?

    func run() async throws {
        for tag in addTags { try Tags.validate(tag) }
        let store = Store()
        try await store.requestEventAccess()
        let event = try store.event(id: id)

        var (tags, cleanTitle) = Tags.parse(event.title ?? "")
        if let title { cleanTitle = title }
        let removals = Set(removeTags.map { $0.lowercased() })
        tags.removeAll { removals.contains($0.lowercased()) }
        for tag in addTags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        event.title = Tags.compose(tags: tags, title: cleanTitle)

        if let start {
            let (date, dateOnly) = try Dates.parseDateTime(start)
            event.startDate = date
            if dateOnly {
                event.isAllDay = true
                event.endDate = date
            } else {
                event.isAllDay = false
            }
        }
        if let end { event.endDate = try Dates.parseDateTime(end).date }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if clearUrl { event.url = nil }
        if let url { event.url = URL(string: url) }
        if let calendarName { event.calendar = try store.eventCalendar(named: calendarName) }

        try store.save(event)
        let out = EventOut(event)
        AuditDB.shared.record(command: "events update", taskId: out.id, list: out.calendar, detail: out.rawTitle)
        emit(out)
    }
}

struct EventsDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an event."
    )

    @Argument(help: "Event id.")
    var id: String

    func run() async throws {
        let store = Store()
        try await store.requestEventAccess()
        let event = try store.event(id: id)
        let out = EventOut(event)
        do {
            try store.ek.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
        AuditDB.shared.record(command: "events delete", taskId: out.id, list: out.calendar, detail: out.rawTitle)
        emit(["deleted": id])
    }
}

struct Calendars: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show Calendar calendars.")

    func run() async throws {
        let store = Store()
        try await store.requestEventAccess()
        let calendars = store.ek.calendars(for: .event)
            .map { CalendarOut(id: $0.calendarIdentifier, name: $0.title, writable: $0.allowsContentModifications) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        emit(calendars)
    }
}
