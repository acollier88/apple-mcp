// iOS 27 / macOS 27 Notes domain schema adoption (IDEAS #29). Positions the
// app as Siri's handle onto our notes surfaces: "Hey Siri, create a note in
// AgentTasks" shells to `apple-tasks notes create`. Property names/types are
// compiler-enforced by the schema macro; discovered by bisection against the
// beta 3 macro plugin (see IDEAS #29 for the full findings).
import AppIntents
import Foundation

@available(macOS 27.0, *)
@AppEntity(schema: .notes.folder)
struct NoteFolderEntity {
    var id: String
    var name: String
    // Computed, not stored: a stored `NoteFolderEntity?` would give the
    // struct infinite size (no `indirect` for structs). We don't model
    // nested folders/accounts today, so both are always nil.
    var account: NoteAccountEntity? { nil }
    var parentFolder: NoteFolderEntity? { nil }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = NoteFolderEntityQuery()
}

@available(macOS 27.0, *)
@AppEntity(schema: .notes.account)
struct NoteAccountEntity {
    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = NoteAccountEntityQuery()
}

@available(macOS 27.0, *)
struct NoteAccountEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoteAccountEntity] { [] }
    func entities(matching string: String) async throws -> [NoteAccountEntity] { [] }
}

@available(macOS 27.0, *)
struct NoteFolderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoteFolderEntity] { [] }
    func entities(matching string: String) async throws -> [NoteFolderEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .notes.note)
struct NoteEntity {
    var id: String
    var name: String
    var content: AttributedString?
    var folder: NoteFolderEntity?
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    var attachments: [IntentFile]

    init(id: String, name: String, content: AttributedString?, folder: NoteFolderEntity? = nil,
         isPinned: Bool = false, creationDate: Date? = nil, modificationDate: Date? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.folder = folder
        self.isPinned = isPinned
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.attachments = []
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = NoteEntityQuery()
}

@available(macOS 27.0, *)
struct NoteEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        try recentNotes().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [NoteEntity] {
        try recentNotes().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [NoteEntity] { try recentNotes() }

    /// Recent notes (last 30 days) — Siri lookup, not a full inbox scan.
    private func recentNotes() throws -> [NoteEntity] {
        struct Note: Decodable {
            let id: String
            let name: String
            let folder: String?
            let body: String
            let created: String
            let modified: String
        }
        let sinceDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let json = try CLI.run(["notes", "scan", "--since", fmt.string(from: sinceDate)])
        let notes = (try? JSONDecoder().decode([Note].self, from: Data(json.utf8))) ?? []
        let iso = ISO8601DateFormatter()
        return notes.prefix(20).map { n in
            NoteEntity(id: n.id, name: n.name, content: AttributedString(n.body),
                      folder: n.folder.map { NoteFolderEntity(id: $0, name: $0) },
                      creationDate: iso.date(from: n.created), modificationDate: iso.date(from: n.modified))
        }
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .notes.createNote)
struct CreateNoteIntent {
    var name: String
    var content: AttributedString?
    var folder: NoteFolderEntity?
    var isPinned: Bool
    var attachments: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> {
        let title = name
        let bodyText = content.map { String($0.characters) } ?? ""
        // notes create wants HTML; a plain-text Siri dictation is safe as
        // literal text (no markup to escape beyond what HTML.escape does CLI-side).
        var args = ["notes", "create", "--title", title]
        if let folder { args += ["--folder", folder.name] }
        args.append(bodyText)
        let json = try CLI.run(args)

        struct Created: Decodable { let id: String; let name: String }
        let created = try JSONDecoder().decode(Created.self, from: Data(json.utf8))
        return .result(value: NoteEntity(id: created.id, name: created.name,
                                         content: content, folder: folder, isPinned: isPinned))
    }
}
