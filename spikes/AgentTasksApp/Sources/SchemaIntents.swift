// iOS 27 / macOS 27 Reminders domain schema adoption.
// Schema conformance is compiler-enforced: the @AppIntent/@AppEntity/@AppEnum
// macros validate that our shapes match what the new Siri expects for the
// domain. Notably, `tags` is a first-class Set<String> in Apple's schema —
// our [tag] convention maps straight onto it.
import AppIntents
import Foundation
import GeoToolbox

@available(macOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum ListType: String {
    case standard
    case groceries

    static let caseDisplayRepresentations: [ListType: DisplayRepresentation] = [
        .standard: "Standard",
        .groceries: "Groceries",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum LocationTriggerEvent: String {
    case arrive
    case depart

    static let caseDisplayRepresentations: [LocationTriggerEvent: DisplayRepresentation] = [
        .arrive: "Arriving",
        .depart: "Departing",
    ]
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct PlanEntity {
    var id: String
    var name: String
    var type: ListType

    init(id: String, name: String, type: ListType = .standard) {
        self.id = id
        self.name = name
        self.type = type
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = PlanEntityQuery()
}

@available(macOS 27.0, *)
struct PlanEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlanEntity] {
        try allPlans().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlanEntity] {
        try allPlans().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [PlanEntity] {
        try allPlans()
    }

    private func allPlans() throws -> [PlanEntity] {
        struct List: Decodable {
            let id: String
            let name: String
        }
        let json = try CLI.run(["lists"])
        let lists = (try? JSONDecoder().decode([List].self, from: Data(json.utf8))) ?? []
        return lists.map { PlanEntity(id: $0.id, name: $0.name) }
    }
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct SectionEntity {
    var id: String
    var name: String
    var list: PlanEntity

    init(id: String, name: String, list: PlanEntity) {
        self.id = id
        self.name = name
        self.list = list
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = SectionEntityQuery()
}

@available(macOS 27.0, *)
struct SectionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SectionEntity] { [] }
    func entities(matching string: String) async throws -> [SectionEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct LocationTriggerEntity {
    var id: String
    var event: LocationTriggerEvent
    var place: PlaceDescriptor

    init(id: String, event: LocationTriggerEvent, place: PlaceDescriptor) {
        self.id = id
        self.event = event
        self.place = place
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Location trigger")
    }

    static let defaultQuery = LocationTriggerEntityQuery()
}

@available(macOS 27.0, *)
struct LocationTriggerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LocationTriggerEntity] { [] }
    func entities(matching string: String) async throws -> [LocationTriggerEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct TaskEntity {
    var id: String
    var title: String
    var isCompleted: Bool
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var completionDate: Date?
    var creationDate: Date?
    var isFlagged: Bool?
    var note: AttributedString?
    var recurrence: Calendar.RecurrenceRule?
    var list: PlanEntity
    var locationTrigger: LocationTriggerEntity?

    init(id: String, title: String, isCompleted: Bool, tags: Set<String>, list: PlanEntity,
         dueDate: DateComponents? = nil, completionDate: Date? = nil, creationDate: Date? = nil,
         note: AttributedString? = nil) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.tags = tags
        self.urls = []
        self.dueDate = dueDate
        self.completionDate = completionDate
        self.creationDate = creationDate
        self.isFlagged = nil
        self.note = note
        self.recurrence = nil
        self.list = list
        self.locationTrigger = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    static let defaultQuery = TaskEntityQuery()
}

@available(macOS 27.0, *)
struct TaskEntityQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        try allTasks().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        try allTasks().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        try Array(allTasks().prefix(10))
    }

    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        let tasks = try await entities(for: identifiers)
        try await CSSearchableIndex.default().indexAppEntities(tasks, priority: 0)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let tasks = try allTasks()
        try await CSSearchableIndex.default().indexAppEntities(tasks, priority: 0)
    }

    func allTasks() throws -> [TaskEntity] {
        struct Task: Decodable {
            let id: String
            let title: String
            let tags: [String]
            let list: String
            let completed: Bool
            let notes: String?
        }
        let json = try CLI.run(["list", "--status", "open"])
        let tasks = (try? JSONDecoder().decode([Task].self, from: Data(json.utf8))) ?? []
        return tasks.map { task in
            TaskEntity(
                id: task.id,
                title: task.title,
                isCompleted: task.completed,
                tags: Set(task.tags),
                list: PlanEntity(id: task.list, name: task.list),
                note: task.notes.map { AttributedString($0) }
            )
        }
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct CreateReminderIntent {
    var title: String
    var tags: Set<String>
    var urls: [URL]
    var images: [IntentFile]
    var dueDate: DateComponents?
    var isFlagged: Bool?
    var note: AttributedString?
    var recurrence: Calendar.RecurrenceRule?
    var list: PlanEntity?
    var section: SectionEntity?
    var locationTrigger: LocationTriggerEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> {
        var args = ["add", "--list", list?.name ?? "Code Tasks"]
        let allTags = tags.isEmpty ? ["siri"] : Array(tags)
        for tag in allTags { args += ["--tag", tag] }
        if let note { args += ["--notes", String(note.characters)] }
        args.append(title)
        let json = try CLI.run(args)

        struct Created: Decodable {
            let id: String
            let title: String
            let tags: [String]
            let list: String
        }
        let created = try JSONDecoder().decode(Created.self, from: Data(json.utf8))
        return .result(value: TaskEntity(
            id: created.id,
            title: created.title,
            isCompleted: false,
            tags: Set(created.tags),
            list: PlanEntity(id: created.list, name: created.list)
        ))
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .reminders.updateReminder)
struct UpdateReminderIntent {
    var target: TaskEntity
    var title: String?
    var isCompleted: Bool?
    var tags: Set<String>?
    var urls: [URL]?
    var dueDate: DateComponents?
    var isFlagged: Bool?
    var note: AttributedString?
    var recurrence: Calendar.RecurrenceRule?
    var list: PlanEntity?
    var locationTrigger: LocationTriggerEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> {
        var args = ["update", target.id]
        if let title { args += ["--title", title] }
        if let note { args += ["--notes", String(note.characters)] }
        if let list { args += ["--list", list.name] }
        if let tags {
            for tag in tags.subtracting(target.tags) { args += ["--add-tag", tag] }
            for tag in target.tags.subtracting(tags) { args += ["--remove-tag", tag] }
        }
        if let dueDate, let date = Calendar.current.date(from: dueDate) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = dueDate.hour != nil ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            args += ["--due", formatter.string(from: date)]
        }
        if args.count > 2 {
            _ = try CLI.run(args)
        }
        if let isCompleted {
            _ = try CLI.run([isCompleted ? "complete" : "uncomplete", target.id])
        }

        let json = try CLI.run(["show", target.id])
        struct Task: Decodable {
            let id: String
            let title: String
            let tags: [String]
            let list: String
            let completed: Bool
            let notes: String?
        }
        let task = try JSONDecoder().decode(Task.self, from: Data(json.utf8))
        return .result(value: TaskEntity(
            id: task.id, title: task.title, isCompleted: task.completed,
            tags: Set(task.tags), list: PlanEntity(id: task.list, name: task.list),
            note: task.notes.map { AttributedString($0) }
        ))
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .reminders.deleteReminders)
struct DeleteRemindersIntent {
    typealias Entity = TaskEntity

    var entities: [TaskEntity]

    func perform() async throws -> some IntentResult {
        for entity in entities {
            _ = try CLI.run(["delete", entity.id])
        }
        return .result()
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .reminders.createList)
struct CreateListIntent {
    var name: String?
    var type: ListType

    func perform() async throws -> some IntentResult & ReturnsValue<PlanEntity> {
        struct Created: Decodable { let id: String; let name: String }
        let json = try CLI.run(["lists", "add", name ?? "New Plan"])
        let created = try JSONDecoder().decode(Created.self, from: Data(json.utf8))
        return .result(value: PlanEntity(id: created.id, name: created.name))
    }
}

// Spotlight semantic indexing: tasks become searchable entities with tags as
// keywords. Donated on app launch.
import CoreSpotlight

@available(macOS 27.0, *)
extension TaskEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.keywords = Array(tags)
        attributes.containerTitle = list.name
        if let note { attributes.contentDescription = String(note.characters) }
        return attributes
    }
}

@available(macOS 27.0, *)
enum SpotlightDonation {
    static func donateOpenTasks() async {
        await donateAllOpenTasks()
    }

    static func donateAllOpenTasks() async {
        guard let tasks = try? TaskEntityQuery().allTasks() else { return }
        try? await CSSearchableIndex.default().indexAppEntities(tasks, priority: 0)
    }

    static func updateTask(_ task: TaskEntity) async {
        try? await CSSearchableIndex.default().indexAppEntities([task], priority: 0)
    }

    static func removeTask(id: String) async {
        try? await CSSearchableIndex.default().deleteAppEntities(withIdentifiers: [id])
    }
}
