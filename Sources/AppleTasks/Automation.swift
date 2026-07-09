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

// MARK: - Scan watermark state (~/.config/apple-tasks/state.json)

struct ScanState: Codable {
    var notesScanWatermark: String?
    var screenshotsScanWatermark: String?
    var filesScanWatermark: String?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/state.json")
    }

    static func load() -> ScanState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScanState.self, from: data)
        else { return ScanState() }
        return state
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.url)
    }
}
