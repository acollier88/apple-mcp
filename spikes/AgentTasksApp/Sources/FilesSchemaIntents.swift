// iOS 27 / macOS 27 Files domain schema adoption (IDEAS #29).
// Positions the app as Siri's handle onto our file drop surfaces: the
// entity query surfaces recent AgentInbox drops, and "open <file>" resolves
// against them. The SDK's files domain exposes only a `file` entity (no
// folder) and openFile/createFolder/renameFile/moveFiles/deleteFiles
// intents; we adopt file + openFile. Findings (validated against the beta 3
// appintentsmetadataprocessor, like reminders/notes):
// - the schema conforms the type to the SDK's marker protocol, which is
//   itself named `FileEntity` -- the app type must use a different name
// - that protocol pins `ID == FileEntityIdentifier` (not String) and
//   requires `supportedContentTypes: [UTType]`
import AppIntents
import Foundation
import AppKit
import UniformTypeIdentifiers

@available(macOS 27.0, *)
@AppEntity(schema: .files.file)
struct InboxFileEntity {
    static let supportedContentTypes: [UTType] = [.plainText, .text]

    var id: FileEntityIdentifier
    var name: String
    var creationDate: Date?
    var fileModificationDate: Date?

    init(id: FileEntityIdentifier, name: String, fileModificationDate: Date? = nil) {
        self.id = id
        self.name = name
        self.fileModificationDate = fileModificationDate
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = InboxFileEntityQuery()
}

@available(macOS 27.0, *)
struct InboxFileEntityQuery: EntityStringQuery {
    func entities(for identifiers: [FileEntityIdentifier]) async throws -> [InboxFileEntity] {
        try recentFiles().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [InboxFileEntity] {
        try recentFiles().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [InboxFileEntity] { try recentFiles() }

    /// Recent files in the inbox drop folder (last 30 days) via 'files scan'.
    private func recentFiles() throws -> [InboxFileEntity] {
        struct FileDrop: Decodable {
            let file: String
            let modified: String
            let content: String
        }
        let sinceDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let json = try CLI.run(["files", "scan", "--since", fmt.string(from: sinceDate)])
        let files = (try? JSONDecoder().decode([FileDrop].self, from: Data(json.utf8))) ?? []
        return files.prefix(20).compactMap { f in
            let url = URL(fileURLWithPath: f.file)
            guard let id = try? FileEntityIdentifier.file(url: url) else { return nil }
            return InboxFileEntity(id: id, name: url.lastPathComponent,
                                   fileModificationDate: ISO8601DateFormatter().date(from: f.modified))
        }
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .files.openFile)
struct OpenFileIntent {
    @Parameter var target: InboxFileEntity

    func perform() async throws -> some IntentResult {
        guard let url = try await target.id.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return .result()
        }
        // NSWorkspace.open is UI-bound
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
        return .result()
    }
}
