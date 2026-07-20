import AppKit
import Foundation
import UniformTypeIdentifiers

/// Task recipes: reusable Add Task templates (title, notes, tags, schedule).
///
/// Live copies live in `~/.config/apple-tasks/recipes/*.json`. Bundled examples
/// under `AgentTasks.app/Contents/Resources/recipes/` are seeded into that
/// directory on first load (missing ids only — never overwrite user edits).
enum RecipesStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/recipes")
    }

    struct Recipe: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var description: String?
        var title: String
        var notes: String?
        var list: String?
        var agent: String?
        /// agents.json workdirs tag (optional).
        var workdir: String?
        /// Extra tags beyond agent/workdir/auto (e.g. research).
        var tags: [String]?
        var priority: String?
        var includeAuto: Bool?
        /// Wall-clock time `HH:mm` for the first due (local). Combined with
        /// `dueOffsetDays` when creating a task.
        var dueTime: String?
        /// Days from today to anchor the first due (0 = today / next HH:mm).
        var dueOffsetDays: Int?
        /// RRULE subset accepted by `apple-tasks add --recurrence`.
        var recurrence: String?

        enum CodingKeys: String, CodingKey {
            case id, name, description, title, notes, list, agent, workdir
            case tags, priority, includeAuto, dueTime, dueOffsetDays, recurrence
        }
    }

    // MARK: - Load / seed

    /// Ensure config dir exists, seed bundled recipes that are missing, return all.
    @discardableResult
    static func load(seedingBundled: Bool = true) -> [Recipe] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if seedingBundled {
            seedBundledIfNeeded()
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var recipes: [Recipe] = []
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let recipe = try? decoder.decode(Recipe.self, from: data) else { continue }
            recipes.append(recipe)
        }
        return recipes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func seedBundledIfNeeded() {
        let existing = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { ($0 as NSString).deletingPathExtension.lowercased() }
        )
        for url in bundledRecipeURLs() {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !existing.contains(stem) else { continue }
            let dest = directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    private static func bundledRecipeURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "recipes") {
            urls.append(contentsOf: bundled)
        }
        // Dev fallback: monorepo examples/ when running from a source build.
        let repoExamples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // AgentTasks
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("examples/recipes")
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: repoExamples,
            includingPropertiesForKeys: nil
        ) {
            urls.append(contentsOf: kids.filter { $0.pathExtension.lowercased() == "json" })
        }
        return urls
    }

    // MARK: - Persist

    static func save(_ recipe: Recipe) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cleaned = recipe
        cleaned.id = sanitizeId(recipe.id.isEmpty ? recipe.name : recipe.id)
        guard !cleaned.id.isEmpty else {
            throw NSError(domain: "AgentTasks", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Recipe needs a name/id"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(cleaned)
        let url = directory.appendingPathComponent("\(cleaned.id).json")
        try data.write(to: url, options: .atomic)
    }

    static func sanitizeId(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
            return "-"
        }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    // MARK: - Import / export panels

    @MainActor
    static func importFromPanel() -> Recipe? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Import a task recipe"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            var recipe = try JSONDecoder().decode(Recipe.self, from: data)
            if recipe.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recipe.id = sanitizeId(url.deletingPathExtension().lastPathComponent)
            }
            try save(recipe)
            return recipe
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    @MainActor
    static func exportToPanel(_ recipe: Recipe) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(sanitizeId(recipe.id)).json"
        panel.message = "Export task recipe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(recipe).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Due formatting for CLI

    /// Build `yyyy-MM-dd HH:mm` for `apple-tasks add --due`, or nil if no schedule.
    static func dueArgument(dueTime: String?, offsetDays: Int?, now: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        guard let dueTime, !dueTime.isEmpty else { return nil }
        let parts = dueTime.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        let offset = offsetDays ?? 0
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var date = calendar.date(from: comps) else { return nil }
        if offset != 0 {
            date = calendar.date(byAdding: .day, value: offset, to: date) ?? date
        }
        // If anchoring "today" and the clock already passed, roll to tomorrow
        // so a 7am daily recipe created at 6pm still schedules correctly.
        if offset == 0, date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
