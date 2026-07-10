import ArgumentParser
import EventKit
import Foundation

@main
struct AppleTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-tasks",
        abstract: "Manage Apple Reminders as agent tasks using a [tag] title-prefix convention.",
        version: "0.1.0",
        subcommands: [
            ListTasks.self, Show.self, Add.self, Update.self,
            Complete.self, Uncomplete.self, Delete.self, Lists.self,
            Events.self, Calendars.self,
            Notes.self, Mail.self, ContactsCommand.self, Doctor.self,
            Dispatch.self, Dispatches.self, Log.self,
            Whereami.self, NotifyCommand.self, Triage.self, Digest.self,
            Screenshots.self, Files.self, ReadingList.self,
        ]
    )
}

enum StatusFilter: String, ExpressibleByArgument {
    case open, completed, all
}

enum PriorityArg: String, ExpressibleByArgument {
    case none, low, medium, high
}

// MARK: - list

struct ListTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tasks, filterable by list, tag, and status."
    )

    @Option(name: .customLong("list"), help: "Only tasks in this Reminders list.")
    var listName: String?

    @Option(name: [.customShort("t"), .customLong("tag")], help: "Require this tag (repeatable; AND).")
    var tags: [String] = []

    @Option(help: "open | completed | all (default: open).")
    var status: StatusFilter = .open

    @Option(name: .customLong("due-before"), help:
        "Only tasks due before this date: yyyy-MM-dd (inclusive of that whole day), 'yyyy-MM-dd HH:mm', or ISO8601. Tasks with no due date are excluded.")
    var dueBefore: String?

    @Flag(help: "Only tasks whose due date has passed (excludes undated tasks).")
    var overdue = false

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        let calendars = try listName.map { [try store.calendar(named: $0)] }
        var reminders = await store.reminders(in: calendars)

        switch status {
        case .open: reminders = reminders.filter { !$0.isCompleted }
        case .completed: reminders = reminders.filter { $0.isCompleted }
        case .all: break
        }

        var dueCutoff: Date?
        if let dueBefore {
            let (date, dateOnly) = try Dates.parseDateTime(dueBefore)
            // A date-only bound should include that whole day.
            dueCutoff = dateOnly ? date.addingTimeInterval(86_400) : date
        }
        if overdue {
            dueCutoff = min(dueCutoff ?? .distantFuture, Date())
        }
        if let dueCutoff {
            let calendar = Calendar.current
            reminders = reminders.filter { r in
                guard let comps = r.dueDateComponents, let due = calendar.date(from: comps)
                else { return false }
                return due < dueCutoff
            }
        }

        var tasks = reminders.map(TaskOut.init)
        if !tags.isEmpty {
            let wanted = Set(tags.map { $0.lowercased() })
            tasks = tasks.filter { wanted.isSubset(of: $0.tags.map { $0.lowercased() }) }
        }
        emit(tasks)
    }
}

// MARK: - show

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a single task by id.")

    @Argument(help: "Task id (internal or external identifier).")
    var id: String

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        emit(TaskOut(try await store.reminder(id: id)))
    }
}

// MARK: - add

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a task in a list, with tags.")

    @Option(name: .customLong("list"), help: "Reminders list to add the task to.")
    var listName: String

    @Option(name: [.customShort("t"), .customLong("tag")], help: "Tag to prefix onto the title (repeatable).")
    var tags: [String] = []

    @Option(help: "Notes body.")
    var notes: String?

    @Option(help: "Due date: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601.")
    var due: String?

    @Option(help: "none | low | medium | high.")
    var priority: PriorityArg?

    @Option(help: "URL to attach (shows natively in Reminders; use for PR/artifact links).")
    var url: String?

    @Flag(name: .customLong("no-native-tags"), help: "Skip mirroring tags to native Reminders tags.")
    var noNativeTags = false

    @Argument(help: "Task title (without tag prefix).")
    var title: String

    func run() async throws {
        for tag in tags { try Tags.validate(tag) }
        let store = Store()
        try await store.requestAccess()

        let reminder = EKReminder(eventStore: store.ek)
        reminder.calendar = try store.calendar(named: listName)
        reminder.title = Tags.compose(tags: tags, title: title)
        reminder.notes = notes
        if let url { reminder.url = URL(string: url) }
        if let due { reminder.dueDateComponents = try Dates.parseDue(due) }
        if let priority { reminder.priority = Priority(rawValue: priority.rawValue)!.ekValue }

        try store.save(reminder)
        var out = TaskOut(reminder)
        if !noNativeTags {
            out.nativeTags = NativeTags.mirror(tags: tags, externalId: reminder.calendarItemExternalIdentifier)
        }
        AuditDB.shared.record(command: "add", taskId: out.id, list: out.list, detail: out.rawTitle)
        emit(out)
    }
}

// MARK: - update

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update a task's title, tags, notes, due date, priority, or list.")

    @Argument(help: "Task id.")
    var id: String

    @Option(help: "New title (tag prefix is preserved).")
    var title: String?

    @Option(name: .customLong("add-tag"), help: "Add a tag (repeatable).")
    var addTags: [String] = []

    @Option(name: .customLong("remove-tag"), help: "Remove a tag (repeatable, case-insensitive).")
    var removeTags: [String] = []

    @Option(help: "New notes body.")
    var notes: String?

    @Option(name: .customLong("append-notes"),
            help: "Append a paragraph to the notes (keeps the existing body).")
    var appendNotes: String?

    @Option(help: "New due date: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601.")
    var due: String?

    @Flag(name: .customLong("clear-due"), help: "Remove the due date.")
    var clearDue = false

    @Option(help: "none | low | medium | high.")
    var priority: PriorityArg?

    @Option(name: .customLong("list"), help: "Move the task to this list.")
    var listName: String?

    @Option(help: "Set the task URL (use for PR/artifact links).")
    var url: String?

    @Flag(name: .customLong("clear-url"), help: "Remove the task URL.")
    var clearUrl = false

    @Flag(name: .customLong("no-native-tags"), help: "Skip mirroring added tags to native Reminders tags.")
    var noNativeTags = false

    @Option(name: .customLong("parent"), help: "Make this task a subtask of the given task id (private ReminderKit helper).")
    var parent: String?

    // NOTE: no --clear-parent. The helper CAN detach (removeFromParentReminder,
    // proven at the ReminderKit layer), but a detached reminder is not re-filed
    // into a list calendar and so becomes invisible to EventKit — effectively
    // data loss from every EventKit-based surface. Left unexposed until the
    // re-file step is figured out (IDEAS #26).

    func run() async throws {
        for tag in addTags { try Tags.validate(tag) }
        let store = Store()
        try await store.requestAccess()
        let reminder = try await store.reminder(id: id)

        var (tags, cleanTitle) = Tags.parse(reminder.title ?? "")
        if let title { cleanTitle = title }
        let removals = Set(removeTags.map { $0.lowercased() })
        tags.removeAll { removals.contains($0.lowercased()) }
        for tag in addTags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        reminder.title = Tags.compose(tags: tags, title: cleanTitle)

        if let notes { reminder.notes = notes }
        if let appendNotes {
            let existing = reminder.notes.map { $0.isEmpty ? "" : $0 + "\n\n" } ?? ""
            reminder.notes = existing + appendNotes
        }
        if clearDue { reminder.dueDateComponents = nil }
        if let due { reminder.dueDateComponents = try Dates.parseDue(due) }
        if clearUrl { reminder.url = nil }
        if let url { reminder.url = URL(string: url) }
        if let priority { reminder.priority = Priority(rawValue: priority.rawValue)!.ekValue }
        if let listName { reminder.calendar = try store.calendar(named: listName) }

        try store.save(reminder)
        var out = TaskOut(reminder)
        if !noNativeTags && !addTags.isEmpty {
            out.nativeTags = NativeTags.mirror(tags: addTags, externalId: reminder.calendarItemExternalIdentifier)
        }
        // Subtask relationship (IDEAS #26) via the private helper. Resolve the
        // parent's sync-stable externalId; save the reminder first so its own
        // externalId exists before the helper looks it up.
        if let parent {
            let parentReminder = try await store.reminder(id: parent)
            guard let parentExternalId = parentReminder.calendarItemExternalIdentifier, !parentExternalId.isEmpty else {
                throw AppleTasksError.saveFailed("parent task has no external identifier yet")
            }
            out.subtask = NativeTags.setParent(childExternalId: reminder.calendarItemExternalIdentifier,
                                               parentExternalId: parentExternalId)
        }
        AuditDB.shared.record(command: "update", taskId: out.id, list: out.list, detail: out.rawTitle)
        emit(out)
    }
}

// MARK: - complete / uncomplete / delete

struct Complete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mark a task completed.")

    @Argument(help: "Task id.")
    var id: String

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        let reminder = try await store.reminder(id: id)
        reminder.isCompleted = true
        try store.save(reminder)
        let out = TaskOut(reminder)
        AuditDB.shared.record(command: "complete", taskId: out.id, list: out.list, detail: out.rawTitle)
        emit(out)
    }
}

struct Uncomplete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mark a completed task open again.")

    @Argument(help: "Task id.")
    var id: String

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        let reminder = try await store.reminder(id: id)
        reminder.isCompleted = false
        try store.save(reminder)
        let out = TaskOut(reminder)
        AuditDB.shared.record(command: "uncomplete", taskId: out.id, list: out.list, detail: out.rawTitle)
        emit(out)
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a task.")

    @Argument(help: "Task id.")
    var id: String

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        let reminder = try await store.reminder(id: id)
        let out = TaskOut(reminder)
        do {
            try store.ek.remove(reminder, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
        AuditDB.shared.record(command: "delete", taskId: out.id, list: out.list, detail: out.rawTitle)
        emit(["deleted": id])
    }
}

// MARK: - lists

struct Lists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show Reminders lists (plans), or create one.",
        subcommands: [ListsAdd.self]
    )

    func run() async throws {
        let store = Store()
        try await store.requestAccess()
        let lists = store.ek.calendars(for: .reminder)
            .map { ListOut(id: $0.calendarIdentifier, name: $0.title) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        emit(lists)
    }
}

struct ListsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a new Reminders list (plan)."
    )

    @Argument(help: "Name for the new list.")
    var name: String

    func run() async throws {
        let store = Store()
        try await store.requestAccess()

        let calendar = EKCalendar(for: .reminder, eventStore: store.ek)
        calendar.title = name
        guard let source = store.ek.defaultCalendarForNewReminders()?.source
            ?? store.ek.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.ek.sources.first(where: { $0.sourceType == .local })
        else {
            throw AppleTasksError.noSource
        }
        calendar.source = source
        do {
            try store.ek.saveCalendar(calendar, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
        AuditDB.shared.record(command: "lists add", list: calendar.title)
        emit(ListOut(id: calendar.calendarIdentifier, name: calendar.title))
    }
}
