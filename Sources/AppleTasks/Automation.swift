import Foundation

// MARK: - osascript runner (Notes/Mail have no public framework; JXA is the only access)

enum OSA {
    static func runJXA(_ script: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            var message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"
            if message.contains("-1743") {
                message += " (Automation permission denied: System Settings > Privacy & Security > Automation, allow your terminal to control the target app.)"
            }
            throw AppleTasksError.automationFailed(message)
        }
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - HTML to plain text (Notes bodies come back as HTML)

enum HTML {
    /// Escape text for embedding in HTML we generate (digest, notes create).
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func toText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(div|p|h1|h2|h3|li|blockquote|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Native tag mirror (private ReminderKit, via the apple-tasks-private helper)

enum NativeTags {
    /// The helper lives next to the main binary; APPLE_TASKS_PRIVATE_BIN overrides.
    static var helperURL: URL? {
        if let override = ProcessInfo.processInfo.environment["APPLE_TASKS_PRIVATE_BIN"] {
            return URL(fileURLWithPath: override)
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("apple-tasks-private")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// Best-effort, additive-only mirror of tags onto the reminder's native
    /// Reminders tags. Returns true on success, false (with a stderr warning)
    /// on any failure — the [tag] title prefix is the source of truth, so a
    /// failed mirror never fails the command.
    static func mirror(tags: [String], externalId: String?) -> Bool? {
        guard !tags.isEmpty else { return nil }
        return run(["externalId": externalId ?? "", "tags": tags], externalId: externalId, what: "native tag mirror")
    }

    /// IDEAS #26: make `externalId` a subtask of `parentExternalId` via the
    /// private helper. Best-effort like mirror — a failure warns, never fails
    /// the command (subtasks are an enhancement over the flat list).
    static func setParent(childExternalId: String?, parentExternalId: String) -> Bool? {
        run(["externalId": childExternalId ?? "", "parent": parentExternalId],
            externalId: childExternalId, what: "subtask")
    }

    /// Detach `externalId` from its parent reminder.
    static func clearParent(externalId: String?) -> Bool? {
        run(["externalId": externalId ?? "", "clearParent": true],
            externalId: externalId, what: "subtask detach")
    }

    /// IDEAS #47: map each externalId to its parent reminder's externalId
    /// (nil value = top-level) via the private helper's read-only parentsOf
    /// op. Returns nil when the helper is missing or fails — dependency
    /// gating then degrades to "no info" and dispatch proceeds.
    static func parents(externalIds: [String]) -> [String: String?]? {
        guard let helper = helperURL, !externalIds.isEmpty else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["parentsOf": externalIds])
            let process = Process()
            process.executableURL = helper
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                  let parents = obj["parents"] as? [String: Any] else { return nil }
            var result: [String: String?] = [:]
            for (key, value) in parents { result[key] = value as? String }
            return result
        } catch {
            return nil
        }
    }

    /// Shared helper invocation: JSON payload on stdin, exit 0 = success.
    private static func run(_ payload: [String: Any], externalId: String?, what: String) -> Bool? {
        guard let helper = helperURL else { return nil }
        guard let externalId, !externalId.isEmpty else {
            FileHandle.standardError.write(Data("warning: \(what) skipped (no external identifier yet)\n".utf8))
            return false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let process = Process()
            process.executableURL = helper
            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = stderr
            try process.run()
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            FileHandle.standardError.write(Data("warning: \(what) failed: \(detail)\n".utf8))
            return false
        } catch {
            FileHandle.standardError.write(Data("warning: \(what) failed: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

// MARK: - Scan watermark state (KV row in the audit DB; IDEAS #44)
//
// Historically ~/.config/apple-tasks/state.json; now the 'scan_state' row in
// apple-tasks.db carries the same JSON payload, so doctor and the ledger read
// one source of truth. A pre-existing state.json is migrated on first load
// and then left behind as a dead artifact.

struct ScanState: Codable {
    var notesScanWatermark: String?
    var screenshotsScanWatermark: String?
    var filesScanWatermark: String?
    var audioScanWatermark: String?
    var readingListScanWatermark: String?
    /// Per-watch scan state (IDEAS #38), keyed by watch name.
    var watchState: [String: WatchRecord]?
    /// NSPasteboard.changeCount at the last clipboard scan (IDEAS #45).
    var clipboardChangeCount: Int?

    static let dbKey = "scan_state"

    /// Legacy file location, read once for migration only.
    static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/state.json")
    }

    static func load() -> ScanState {
        if let json = AuditDB.shared.getState(dbKey),
           let state = try? JSONDecoder().decode(ScanState.self, from: Data(json.utf8)) {
            return state
        }
        // Migrate best-effort: if the DB write fails the file state is still
        // returned, so scans keep their watermarks and save() retries later.
        if let data = try? Data(contentsOf: legacyURL),
           let state = try? JSONDecoder().decode(ScanState.self, from: data) {
            try? state.save()
            return state
        }
        return ScanState()
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8),
              AuditDB.shared.setState(Self.dbKey, json)
        else {
            throw AppleTasksError.saveFailed("could not persist scan state to \(AuditDB.url.path)")
        }
    }
}
