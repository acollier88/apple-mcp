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

// MARK: - Scan watermark state (~/.config/apple-tasks/state.json)

struct ScanState: Codable {
    var notesScanWatermark: String?

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
