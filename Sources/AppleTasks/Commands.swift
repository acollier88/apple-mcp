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
            Notes.self, Mail.self, Doctor.self,
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
        if let due { reminder.dueDateComponents = try Dates.parseDue(due) }
        if let priority { reminder.priority = Priority(rawValue: priority.rawValue)!.ekValue }

        try store.save(reminder)
        var out = TaskOut(reminder)
        if !noNativeTags {
            out.nativeTags = NativeTags.mirror(tags: tags, externalId: reminder.calendarItemExternalIdentifier)
        }
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

    @Option(help: "New due date: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601.")
    var due: String?

    @Flag(name: .customLong("clear-due"), help: "Remove the due date.")
    var clearDue = false

    @Option(help: "none | low | medium | high.")
    var priority: PriorityArg?

    @Option(name: .customLong("list"), help: "Move the task to this list.")
    var listName: String?

    @Flag(name: .customLong("no-native-tags"), help: "Skip mirroring added tags to native Reminders tags.")
    var noNativeTags = false

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
        if clearDue { reminder.dueDateComponents = nil }
        if let due { reminder.dueDateComponents = try Dates.parseDue(due) }
        if let priority { reminder.priority = Priority(rawValue: priority.rawValue)!.ekValue }
        if let listName { reminder.calendar = try store.calendar(named: listName) }

        try store.save(reminder)
        var out = TaskOut(reminder)
        if !noNativeTags && !addTags.isEmpty {
            out.nativeTags = NativeTags.mirror(tags: addTags, externalId: reminder.calendarItemExternalIdentifier)
        }
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
        emit(TaskOut(reminder))
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
        emit(TaskOut(reminder))
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
        do {
            try store.ek.remove(reminder, commit: true)
        } catch {
            throw AppleTasksError.saveFailed(error.localizedDescription)
        }
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
        emit(ListOut(id: calendar.calendarIdentifier, name: calendar.title))
    }
}
