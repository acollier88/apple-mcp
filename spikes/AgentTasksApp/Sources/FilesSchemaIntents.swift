// iOS 27 / macOS 27 Files domain schema adoption (IDEAS #29).
// Positions the app as Siri's handle onto our file drop surfaces.
// Property names/types are speculative (undocumented schemas) and need compilation
// validation against the beta macro plugin (similar to calendar/notes bisection).
import AppIntents
import Foundation
import AppKit

@available(macOS 27.0, *)
@AppEntity(schema: .files.folder)
struct FolderEntity {
    var id: String
    var name: String
    
    // Computed, not stored: avoid recursive struct infinite size.
    var parentFolder: FolderEntity? { nil }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = FolderEntityQuery()
}

@available(macOS 27.0, *)
@AppEntity(schema: .files.file)
struct FileEntity {
    var id: String
    var name: String
    var content: AttributedString?
    var folder: FolderEntity?
    var creationDate: Date?
    var modificationDate: Date?

    init(id: String, name: String, content: AttributedString?, folder: FolderEntity? = nil,
         creationDate: Date? = nil, modificationDate: Date? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.folder = folder
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = FileEntityQuery()
}

@available(macOS 27.0, *)
struct FolderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FolderEntity] { [] }
    func entities(matching string: String) async throws -> [FolderEntity] { [] }
}

@available(macOS 27.0, *)
struct FileEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FileEntity] {
        try recentFiles().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [FileEntity] {
        try recentFiles().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [FileEntity] { try recentFiles() }

    /// Recent files in the inbox drop folder (last 30 days) via 'files scan'.
    private func recentFiles() throws -> [FileEntity] {
        struct FileDrop: Decodable {
            let file: String
            let modified: String
            let content: String
        }
        let sinceDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let json = try CLI.run(["files", "scan", "--since", fmt.string(from: sinceDate)])
        let files = (try? JSONDecoder().decode([FileDrop].self, from: Data(json.utf8))) ?? []
        let iso = ISO8601DateFormatter()
        return files.prefix(20).map { f in
            let url = URL(fileURLWithPath: f.file)
            let filename = url.lastPathComponent
            let modifiedDate = iso.date(from: f.modified)
            return FileEntity(
                id: f.file,
                name: filename,
                content: AttributedString(f.content),
                folder: FolderEntity(id: url.deletingLastPathComponent().path, name: url.deletingLastPathComponent().lastPathComponent),
                modificationDate: modifiedDate
            )
        }
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .files.openFile)
struct OpenFileIntent {
    var target: FileEntity

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: target.id)
        if FileManager.default.fileExists(atPath: url.path) {
            // Run on main actor since NSWorkspace.open is UI-bound
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
        return .result()
    }
}
