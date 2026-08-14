import Foundation

/// Provider/model for a dispatched argv. Requested values come from flags;
/// Cursor `agent --print --output-format stream-json` also reports the Auto
/// pick on the system/init event (`model` display name).
enum AgentSeat {
    struct Info: Sendable {
        var provider: String
        var model: String
        var resolved: String?
        var sessionId: String?

        var logLine: String {
            var line = "# provider=\(provider) model=\(model)"
            if let resolved, resolved != model {
                line += " resolved=\(resolved)"
            }
            if let sessionId { line += " session=\(sessionId)" }
            return line
        }

        var summary: String {
            "provider=\(provider) model=\(resolved ?? model)"
        }
    }

    static func from(argv: [String]) -> Info {
        let bin = URL(fileURLWithPath: argv.first ?? "").lastPathComponent.lowercased()
        switch bin {
        case "agent", "cursor-agent":
            return Info(provider: "cursor", model: option(argv, "--model") ?? "auto")
        case "hermes":
            return Info(
                provider: option(argv, "--provider") ?? "hermes",
                model: option(argv, "-m", "--model") ?? "unknown"
            )
        case "claude":
            return Info(provider: "anthropic", model: option(argv, "--model") ?? "default")
        case "agy", "antigravity":
            return Info(provider: "antigravity", model: option(argv, "--model") ?? "default")
        case "apple-tasks":
            return Info(
                provider: "byom",
                model: option(argv, "--model") ?? option(argv, "--agent") ?? "llm"
            )
        default:
            return Info(provider: bin.isEmpty ? "unknown" : bin, model: option(argv, "--model") ?? "unknown")
        }
    }

    static func isCursorAgent(_ argv: [String]) -> Bool {
        let bin = URL(fileURLWithPath: argv.first ?? "").lastPathComponent.lowercased()
        return bin == "agent" || bin == "cursor-agent"
    }

    static func withStreamJSON(_ argv: [String]) -> [String] {
        if argv.contains("--output-format") { return argv }
        return argv + ["--output-format", "stream-json"]
    }

    static func option(_ argv: [String], _ names: String...) -> String? {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            for name in names {
                if a == name, i + 1 < argv.count { return argv[i + 1] }
                let prefix = name + "="
                if a.hasPrefix(prefix) { return String(a.dropFirst(prefix.count)) }
            }
            i += 1
        }
        return nil
    }
}

/// Turns Cursor `stream-json` NDJSON into a readable run log and captures the
/// resolved Auto model from the system/init event.
final class CursorNDJSONFilter: @unchecked Sendable {
    private let lock = NSLock()
    private let log: FileHandle
    private var buf = Data()
    private(set) var resolvedModel: String?
    private(set) var sessionId: String?
    private var wroteResolved = false

    init(log: FileHandle) {
        self.log = log
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buf.append(data)
        let nl = Data([0x0a])
        while let range = buf.range(of: nl) {
            let line = buf.subdata(in: buf.startIndex..<range.lowerBound)
            buf.removeSubrange(..<range.upperBound)
            handle(line)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buf.isEmpty {
            handle(buf)
            buf.removeAll()
        }
    }

    private func handle(_ raw: Data) {
        let line = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            write(line + "\n")
            return
        }
        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init" {
                if let model = obj["model"] as? String, !model.isEmpty {
                    resolvedModel = model
                }
                if let sid = obj["session_id"] as? String, !sid.isEmpty {
                    sessionId = sid
                }
                if !wroteResolved, resolvedModel != nil || sessionId != nil {
                    wroteResolved = true
                    var bits = ["# resolved"]
                    if let resolvedModel { bits.append("model=\(resolvedModel)") }
                    if let sessionId { bits.append("session=\(sessionId)") }
                    write(bits.joined(separator: " ") + "\n")
                }
            }
        case "assistant":
            if let text = assistantText(obj), !text.isEmpty {
                write(text)
                if !text.hasSuffix("\n") { write("\n") }
            }
        case "tool_call":
            if (obj["subtype"] as? String) == "started", let name = toolName(obj) {
                write("# tool \(name)\n")
            }
        case "result":
            break
        case "user":
            break
        default:
            break
        }
    }

    private func assistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }
        let text = parts.joined()
        return text.isEmpty ? nil : text
    }

    private func toolName(_ obj: [String: Any]) -> String? {
        guard let call = obj["tool_call"] as? [String: Any] else { return nil }
        if call["readToolCall"] != nil { return "read" }
        if call["writeToolCall"] != nil { return "write" }
        if let fn = call["function"] as? [String: Any], let name = fn["name"] as? String {
            return name
        }
        return call.keys.sorted().first
    }

    private func write(_ text: String) {
        if let data = text.data(using: .utf8) {
            log.write(data)
        }
    }
}
