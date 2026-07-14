// iOS 27 / macOS 27 Calendar domain schema adoption (IDEAS #29 revisit).
// "Hey Siri, create an event in AgentTasks" shells to `apple-tasks events
// add`. The schema's large required surface (attendees, organizers, alarms,
// recurrence, travel time, virtual location, union-typed location) is
// satisfied the same way notes satisfied folder hierarchy: computed stub
// properties, plus the @UnionValue() macro for the two union types --
// no new CLI surface required. See IDEAS #29 for the bisection findings.
import AppIntents
import Foundation
import GeoToolbox

// MARK: - Union types demanded by the schema validator

@available(macOS 27.0, *)
@UnionValue()
enum EventLocation {
    case placeDescriptor(PlaceDescriptor)
    case string(String)
}

@available(macOS 27.0, *)
@UnionValue()
enum EventAlarm {
    case duration(Duration)
    case date(Date)
}

// MARK: - Enums

@available(macOS 27.0, *)
@AppEnum(schema: .calendar.eventStatus)
enum EventStatus: String {
    case none
    case confirmed
    case tentative
    case cancelled

    static let caseDisplayRepresentations: [EventStatus: DisplayRepresentation] = [
        .none: "None", .confirmed: "Confirmed", .tentative: "Tentative", .cancelled: "Cancelled",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .calendar.attendeeType)
enum AttendeeType: String {
    case person
    case room
    case resource

    static let caseDisplayRepresentations: [AttendeeType: DisplayRepresentation] = [
        .person: "Person", .room: "Room", .resource: "Resource",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .calendar.attendeeStatus)
enum AttendeeStatus: String {
    case unknown
    case accepted
    case declined
    case tentative

    static let caseDisplayRepresentations: [AttendeeStatus: DisplayRepresentation] = [
        .unknown: "Unknown", .accepted: "Accepted", .declined: "Declined", .tentative: "Tentative",
    ]
}

// MARK: - Entities

@available(macOS 27.0, *)
@AppEntity(schema: .calendar.attendee)
struct AttendeeEntity {
    var id: String
    var title: String
    var person: IntentPerson { IntentPerson(handle: .init(applicationDefined: title)) }
    var status: AttendeeStatus? { nil }
    var type: AttendeeType? { nil }
    var isAttendanceOptional: Bool { false }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static let defaultQuery = AttendeeEntityQuery()
}

@available(macOS 27.0, *)
struct AttendeeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AttendeeEntity] { [] }
    func entities(matching string: String) async throws -> [AttendeeEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .calendar.calendar)
struct CalendarEntity {
    var id: String
    var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static let defaultQuery = CalendarEntityQuery()
}

@available(macOS 27.0, *)
struct CalendarEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CalendarEntity] { [] }
    func entities(matching string: String) async throws -> [CalendarEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .calendar.event)
struct EventEntity {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var calendar: CalendarEntity

    // Stubs: not modeled by apple-tasks events today.
    var alarms: [EventAlarm] { [] }
    var attendees: [AttendeeEntity] { [] }
    var location: EventLocation? { nil }
    var note: String? { nil }
    var organizers: [IntentPerson] { [] }
    var recurrence: Foundation.Calendar.RecurrenceRule? { nil }
    var status: EventStatus? { nil }
    var travelTime: Duration? { nil }
    var virtualLocation: URL? { nil }

    init(id: String, title: String, startDate: Date, endDate: Date, isAllDay: Bool, calendar: CalendarEntity) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendar = calendar
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static let defaultQuery = EventEntityQuery()
}

@available(macOS 27.0, *)
struct EventEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EventEntity] {
        try upcomingEvents().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [EventEntity] {
        try upcomingEvents().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [EventEntity] { Array(try upcomingEvents().prefix(10)) }

    /// Events in the next 30 days via 'events list'.
    private func upcomingEvents() throws -> [EventEntity] {
        struct Event: Decodable {
            let id: String
            let title: String
            let calendar: String
            let start: String?
            let end: String?
            let allDay: Bool
        }
        let json = try CLI.run(["events", "list", "--to",
                                CalendarDates.dayFormatter.string(from: Date().addingTimeInterval(30 * 86_400))])
        let events = (try? JSONDecoder().decode([Event].self, from: Data(json.utf8))) ?? []
        return events.compactMap { e in
            guard let start = e.start.flatMap(CalendarDates.parse) else { return nil }
            let end = e.end.flatMap(CalendarDates.parse) ?? start
            return EventEntity(id: e.id, title: e.title, startDate: start, endDate: end,
                               isAllDay: e.allDay,
                               calendar: CalendarEntity(id: e.calendar, title: e.calendar))
        }
    }
}

enum CalendarDates {
    static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    static let minuteFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt
    }()

    /// EventOut serializes all-day events as yyyy-MM-dd and timed ones as ISO8601.
    static func parse(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s) ?? dayFormatter.date(from: s)
    }
}

// MARK: - Intents

@available(macOS 27.0, *)
@AppIntent(schema: .calendar.createEvent)
struct CreateEventIntent {
    @Parameter var title: String
    @Parameter var startDate: Date
    @Parameter var endDate: Date?
    @Parameter var isAllDay: Bool
    @Parameter var calendar: CalendarEntity
    @Parameter var location: EventLocation?
    @Parameter var note: String?
    @Parameter var recurrence: Foundation.Calendar.RecurrenceRule?
    @Parameter var attendees: [AttendeeEntity]

    func perform() async throws -> some IntentResult & ReturnsValue<EventEntity> {
        var args = ["events", "add", title]
        // A date-only --start makes an all-day event CLI-side.
        if isAllDay {
            args += ["--start", CalendarDates.dayFormatter.string(from: startDate)]
        } else {
            args += ["--start", CalendarDates.minuteFormatter.string(from: startDate)]
            if let endDate {
                args += ["--end", CalendarDates.minuteFormatter.string(from: endDate)]
            }
        }
        args += ["--calendar", calendar.title]
        if case .string(let address) = location { args += ["--location", address] }
        if let note { args += ["--notes", note] }
        // recurrence/attendees are accepted by the schema but not modeled by
        // the CLI yet -- ignored, like notes ignores isPinned/attachments.
        let json = try CLI.run(args)

        struct Created: Decodable {
            let id: String
            let title: String
            let calendar: String
            let allDay: Bool
        }
        let created = try JSONDecoder().decode(Created.self, from: Data(json.utf8))
        return .result(value: EventEntity(
            id: created.id, title: created.title, startDate: startDate,
            endDate: endDate ?? startDate, isAllDay: created.allDay,
            calendar: CalendarEntity(id: created.calendar, title: created.calendar)))
    }
}
