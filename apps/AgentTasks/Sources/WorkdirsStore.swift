import AppKit
import Foundation

/// Read/write `workdirs` in ~/.config/apple-tasks/agents.json without clobbering
/// the rest of the config (agents, triage, etc.).
enum WorkdirsStore {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/agents.json")
    }

    struct Entry: Identifiable, Hashable {
        var id: String { tag }
        let tag: String
        let path: String
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workdirs = root["workdirs"] as? [String: String] else {
            return []
        }
        return workdirs
            .map { Entry(tag: $0.key, path: ($0.value as NSString).expandingTildeInPath) }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    /// Upsert a workdir tag → absolute path. Creates a minimal agents.json if missing.
    @discardableResult
    static func upsert(tag: String, path: String) throws -> Entry {
        let cleanedTag = sanitizeTag(tag)
        guard !cleanedTag.isEmpty else {
            throw NSError(domain: "AgentTasks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid workdir tag"])
        }
        var absPath = (path as NSString).expandingTildeInPath
        absPath = URL(fileURLWithPath: absPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absPath, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "AgentTasks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(absPath)"])
        }

        var root: [String: Any]
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        } else {
            root = ["agents": [String: Any](), "requireAutoTag": true]
        }
        var workdirs = root["workdirs"] as? [String: String] ?? [:]
        workdirs[cleanedTag] = absPath
        root["workdirs"] = workdirs

        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: configURL, options: .atomic)
        return Entry(tag: cleanedTag, path: absPath)
    }

    /// First task tag that matches a configured workdir (case-insensitive), if any.
    static func matchingTag(in tags: [String], workdirs: [Entry]? = nil) -> String? {
        let entries = workdirs ?? load()
        let keys = Dictionary(uniqueKeysWithValues: entries.map { ($0.tag.lowercased(), $0.tag) })
        for tag in tags {
            if let match = keys[tag.lowercased()] { return match }
        }
        return nil
    }

    static func sanitizeTag(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
            return "-"
        }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    static func tagFromDirectoryName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let tag = sanitizeTag(name)
        return tag.isEmpty ? "repo" : tag
    }

    /// Modal directory picker. Returns nil if the user cancels.
    @MainActor
    static func pickDirectory(startingAt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Select the git repository / working directory for this workdir tag."
        if let startingAt {
            panel.directoryURL = URL(fileURLWithPath: (startingAt as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
