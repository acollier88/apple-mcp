import EventKit
import Foundation

// MARK: - Errors

enum AppleTasksError: Error, CustomStringConvertible {
    case accessDenied
    case calendarAccessDenied
    case listNotFound(String)
    case calendarNotFound(String)
    case taskNotFound(String)
    case eventNotFound(String)
    case invalidDate(String)
    case invalidTag(String)
    case noSource
    case saveFailed(String)
    case automationFailed(String)

    var description: String {
        switch self {
        case .accessDenied:
            return "Reminders access denied. Grant access in System Settings > Privacy & Security > Reminders (the prompt is attributed to the terminal/app that launched this command)."
        case .calendarAccessDenied:
            return "Calendar access denied. Grant access in System Settings > Privacy & Security > Calendars (the prompt is attributed to the terminal/app that launched this command)."
        case .listNotFound(let name):
            return "No Reminders list named '\(name)'. Run 'apple-tasks lists' to see available lists."
        case .calendarNotFound(let name):
            return "No calendar named '\(name)'. Run 'apple-tasks calendars' to see available calendars."
        case .taskNotFound(let id):
            return "No task with id '\(id)'."
        case .eventNotFound(let id):
            return "No event with id '\(id)'."
        case .invalidDate(let s):
            return "Could not parse date '\(s)'. Use yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601."
        case .invalidTag(let t):
            return "Invalid tag '\(t)'. Tags cannot contain spaces or brackets; use kebab-case (e.g. sign-in)."
        case .noSource:
            return "No writable Reminders source found to create a list in."
        case .saveFailed(let why):
            return "Save failed: \(why)"
        case .automationFailed(let why):
            return "Automation failed: \(why)"
        }
    }
}

// MARK: - Tag convention: "[tag1][tag2] Title"

enum Tags {
    /// Splits leading `[tag]` groups off a raw reminder title.
    /// Only leading bracket groups count; whitespace between groups is allowed.
    static func parse(_ raw: String) -> (tags: [String], title: String) {
        var tags: [String] = []
        var rest = Substring(raw)
        while true {
            let trimmed = rest.drop(while: { $0 == " " })
            guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { break }
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            guard !tag.isEmpty, !tag.contains(" "), !tag.contains("[") else { break }
            tags.append(String(tag))
            rest = trimmed[trimmed.index(after: close)...]
        }
        return (tags, rest.trimmingCharacters(in: .whitespaces))
    }

    static func compose(tags: [String], title: String) -> String {
        guard !tags.isEmpty else { return title }
        return tags.map { "[\($0)]" }.joined() + " " + title
    }

    static func validate(_ tag: String) throws {
        if tag.isEmpty || tag.contains(" ") || tag.contains("[") || tag.contains("]") {
            throw AppleTasksError.invalidTag(tag)
        }
    }
}

// MARK: - Dates

enum Dates {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// Accepts "yyyy-MM-dd" (date-only), "yyyy-MM-dd HH:mm", or ISO8601.
    static func parseDateTime(_ s: String) throws -> (date: Date, dateOnly: Bool) {
        if let d = formatter("yyyy-MM-dd").date(from: s) {
            return (d, true)
        }
        if let d = formatter("yyyy-MM-dd HH:mm").date(from: s) {
            return (d, false)
        }
        if let d = ISO8601DateFormatter().date(from: s) {
            return (d, false)
        }
        throw AppleTasksError.invalidDate(s)
    }

    /// Accepts "yyyy-MM-dd" (all-day), "yyyy-MM-dd HH:mm", or ISO8601.
    static func parseDue(_ s: String) throws -> DateComponents {
        if let d = formatter("yyyy-MM-dd").date(from: s) {
            return Calendar.current.dateComponents([.year, .month, .day], from: d)
        }
        if let d = formatter("yyyy-MM-dd HH:mm").date(from: s) {
            return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
        if let d = ISO8601DateFormatter().date(from: s) {
            return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
        throw AppleTasksError.invalidDate(s)
    }

    static func formatDue(_ comps: DateComponents?) -> String? {
        guard let comps, let date = Calendar.current.date(from: comps) else { return nil }
        let format = comps.hour != nil ? "yyyy-MM-dd'T'HH:mm:ssZZZZZ" : "yyyy-MM-dd"
        return formatter(format).string(from: date)
    }

    static func formatTimestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        return formatter("yyyy-MM-dd'T'HH:mm:ssZZZZZ").string(from: date)
    }

    static func format(_ date: Date, _ dateFormat: String) -> String {
        formatter(dateFormat).string(from: date)
    }
}

// MARK: - Priority mapping (EKReminder.priority: 0 none, 1-4 high, 5 medium, 6-9 low)

enum Priority: String, CaseIterable {
    case none, low, medium, high

    init(ek: Int) {
        switch ek {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    var ekValue: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }
}

// MARK: - JSON output models

struct TaskOut: Codable {
    let id: String
    let externalId: String?
    let title: String
    let rawTitle: String
    let tags: [String]
    let list: String
    let notes: String?
    let due: String?
    let priority: String
    let completed: Bool
    let completedAt: String?
    let createdAt: String?
    let url: String?
    /// Set by add/update only: whether tags were also mirrored to native
    /// Reminders tags via the private helper. Omitted when not attempted.
    var nativeTags: Bool?

    init(_ r: EKReminder) {
        let raw = r.title ?? ""
        let parsed = Tags.parse(raw)
        id = r.calendarItemIdentifier
        externalId = r.calendarItemExternalIdentifier
        title = parsed.title
        rawTitle = raw
        tags = parsed.tags
        list = r.calendar?.title ?? ""
        notes = r.notes
        due = Dates.formatDue(r.dueDateComponents)
        priority = Priority(ek: r.priority).rawValue
        completed = r.isCompleted
        completedAt = Dates.formatTimestamp(r.completionDate)
        createdAt = Dates.formatTimestamp(r.creationDate)
        url = r.url?.absoluteString
    }
}

struct ListOut: Codable {
    let id: String
    let name: String
}

struct EventOut: Codable {
    let id: String
    let title: String
    let rawTitle: String
    let tags: [String]
    let calendar: String
    let start: String?
    let end: String?
    let allDay: Bool
    let location: String?
    let notes: String?
    let url: String?

    init(_ e: EKEvent) {
        let raw = e.title ?? ""
        let parsed = Tags.parse(raw)
        id = e.eventIdentifier ?? e.calendarItemIdentifier
        title = parsed.title
        rawTitle = raw
        tags = parsed.tags
        calendar = e.calendar?.title ?? ""
        let dateFormat = e.isAllDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        start = e.startDate.map { Dates.format($0, dateFormat) }
        end = e.endDate.map { Dates.format($0, dateFormat) }
        allDay = e.isAllDay
        location = e.location
        notes = e.notes
        url = e.url?.absoluteString
    }
}

struct CalendarOut: Codable {
    let id: String
    let name: String
    let writable: Bool
}

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else {
        print("{\"error\":\"encoding failed\"}")
        return
    }
    print(json)
}

// MARK: - EventKit store wrapper

final class Store {
    let ek = EKEventStore()

    func requestAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await ek.requestFullAccessToReminders()
        } else {
            granted = try await ek.requestAccess(to: .reminder)
        }
        guard granted else { throw AppleTasksError.accessDenied }
    }

    func calendar(named name: String) throws -> EKCalendar {
        let calendars = ek.calendars(for: .reminder)
        guard let match = calendars.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppleTasksError.listNotFound(name)
        }
        return match
    }

    func reminders(in calendars: [EKCalendar]?) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = ek.predicateForReminders(in: calendars)
            ek.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }
    }

    func reminder(id: String) async throws -> EKReminder {
        if let item = ek.calendarItem(withIdentifier: id) as? EKReminder {
            return item
        }
        // Fall back to the sync-stable external identifier.
        let all = await reminders(in: nil)
        guard let match = all.first(where: { $0.calendarItemExternalIdentifier == id }) else {
            throw AppleTasksError.taskNotFound(id)
        }
        return match
    }

    func save(_ reminder: EKReminder) throws {
        do {
            try ek.save(reminder, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Calendar events

    func requestEventAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await ek.requestFullAccessToEvents()
        } else {
            granted = try await ek.requestAccess(to: .event)
        }
        guard granted else { throw AppleTasksError.calendarAccessDenied }
    }

    func eventCalendar(named name: String) throws -> EKCalendar {
        let calendars = ek.calendars(for: .event)
        guard let match = calendars.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppleTasksError.calendarNotFound(name)
        }
        return match
    }

    func events(from: Date, to: Date, calendars: [EKCalendar]?) -> [EKEvent] {
        let predicate = ek.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return ek.events(matching: predicate)
    }

    func event(id: String) throws -> EKEvent {
        guard let event = ek.event(withIdentifier: id) else {
            throw AppleTasksError.eventNotFound(id)
        }
        return event
    }

    func save(_ event: EKEvent) throws {
        do {
            try ek.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
    }
}
