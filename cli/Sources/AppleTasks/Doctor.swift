import ArgumentParser
import EventKit
import Foundation
import Speech

struct DoctorOut: Codable {
    let binary: String
    let hostProcess: String
    let reminders: String
    let calendars: String
    let location: String
    let contacts: String
    let foundationModels: String
    let findmySidecar: String
    let mailRule: String
    let dropFolder: String
    let privateHelper: PrivateHelperStatus
    let notesScanWatermark: String?
    let speech: String
    let fullDiskAccess: String
    let agentsConfig: String
    let cursorAgent: String
    let launchAgent: String
    let hermes: String
    let hermesGateway: String
    let hermesCron: String
    let homeAssistant: String
    let budget: String
    let automationNote: String

    struct PrivateHelperStatus: Codable {
        let present: Bool
        let path: String?
        let check: String?
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report permission and configuration status for THIS host process, plus Hermes gateway / cron / Home Assistant and Budget Tracker bandwidth. TCC grants are per-host: Terminal working proves nothing about an MCP host app."
    )

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func hostProcessName() -> String {
        let ppid = getppid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", "\(ppid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "pid \(ppid)" }
        process.waitUntilExit()
        let name = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "pid \(ppid)" : "\(name) (pid \(ppid))"
    }

    private static func helperStatus() -> DoctorOut.PrivateHelperStatus {
        guard let helper = NativeTags.helperURL else {
            return .init(present: false, path: nil, check: nil)
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--check"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .init(present: true, path: helper.path, check: "ok")
            }
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "failed"
            return .init(present: true, path: helper.path, check: detail)
        } catch {
            return .init(present: true, path: helper.path, check: error.localizedDescription)
        }
    }

    private static func findmyStatus() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/findmy")
        let session = FileManager.default.fileExists(atPath: dir.appendingPathComponent("account.json").path)
        let accessories = ((try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("accessories").path)) ?? [])
            .filter { $0.hasSuffix(".plist") || $0.hasSuffix(".json") }
            .count
        guard session || accessories > 0 else {
            return "not configured (run: tools/findmy/findmy-sidecar.py login)"
        }
        return "session \(session ? "present" : "MISSING"), \(accessories) accessories"
    }

    private static func speechStatus() -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func fdaStatus() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist").path
        if FileManager.default.isReadableFile(atPath: path) {
            return "granted (Safari bookmarks accessible)"
        } else {
            return "denied or not determined (required for Safari Reading List scan; grant in Settings > Privacy > Full Disk Access)"
        }
    }

    private static func agentsConfigStatus() -> String {
        let path = AgentsConfig.url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return "missing (copy examples/agents.json → \(path), or make install-agent)"
        }
        do {
            let cfg = try AgentsConfig.load()
            let tags = cfg.agents.keys.sorted().joined(separator: ", ")
            let pool = cfg.autoPool().joined(separator: ", ")
            let poolNote = pool.isEmpty ? "auto pool empty" : "auto: \(pool)"
            return "ok (\(cfg.agents.count) agents: \(tags); \(poolNote))"
        } catch {
            return "unreadable: \(error.localizedDescription)"
        }
    }

    /// Resolve a binary on PATH the same way dispatch does (/usr/bin/env).
    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty else { return nil }
        return path
    }

    /// Resolve `agent` (Cursor Agent CLI) on PATH the same way dispatch does (/usr/bin/env).
    private static func cursorAgentStatus() -> String {
        guard let path = which("agent") else {
            return "not found (install: curl https://cursor.com/install -fsS | bash)"
        }
        return "present: \(path) (tag tasks [cursor][auto]; agent login or CURSOR_API_KEY)"
    }

    private static func hermesHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    }

    /// One-line, secret-safe truncation for status strings.
    private static func clip(_ raw: String, limit: Int = 160) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.range(of: #"eyJ[A-Za-z0-9_-]{20,}"#, options: .regularExpression) != nil
            || flat.lowercased().contains("bearer ")
            || flat.contains("sk-") {
            return "[redacted]"
        }
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// True when ~/.hermes/.env has a non-empty KEY= value. Never returns the value.
    private static func dotenvHasKey(_ key: String) -> Bool {
        let url = hermesHome().appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard t.hasPrefix("\(key)=") else { continue }
            return !t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func hermesStatus() -> String {
        let home = hermesHome()
        guard FileManager.default.fileExists(atPath: home.path) else {
            return "not installed (~/.hermes missing)"
        }
        guard let path = which("hermes") else {
            return "config present, binary not on PATH (install: ~/.local/bin/hermes)"
        }
        var bits = ["present: \(path)"]
        if let cfg = try? String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8) {
            if let match = cfg.range(of: #"(?m)^_config_version:\s*(\d+)"#, options: .regularExpression) {
                let line = String(cfg[match])
                let ver = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "?"
                bits.append("config v\(ver)")
            }
        }
        return bits.joined(separator: "; ")
    }

    /// Budget Tracker snapshot used by `[auto]` routing. Secret-free; reports age and per-provider usable lanes.
    private static func budgetStatus() -> String {
        guard let loaded = BudgetBandwidth.loadAllowingStale() else {
            return "missing (\(BudgetBandwidth.defaultURL.path); Budget Tracker writes it on refresh)"
        }
        let ageMin = max(Int(loaded.age / 60), 0)
        let prefix = loaded.age > BudgetBandwidth.staleAfter ? "stale \(ageMin)m" : "ok \(ageMin)m"
        let parts = ["cursor", "claude", "antigravity", "copilot"].compactMap { key -> String? in
            guard let p = loaded.snap.providers[key],
                  let pct = p.usablePercent,
                  let tier = p.usableTier else { return nil }
            if p.lanes.count > 1 {
                let lanes = p.lanes.map { "\($0.name) \(Int($0.percentUsed))%" }.joined(separator: ", ")
                return "\(key) \(tier) \(Int(pct))% (\(lanes))"
            }
            return "\(key) \(tier) \(Int(pct))%"
        }
        let body = parts.isEmpty ? "no providers" : parts.joined(separator: "; ")
        return "\(prefix): \(body)"
    }

    private static func hermesGatewayStatus() -> String {
        let url = hermesHome().appendingPathComponent("gateway_state.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "not running (no ~/.hermes/gateway_state.json)"
        }
        guard let obj = jsonObject(at: url) else {
            return "unreadable ~/.hermes/gateway_state.json"
        }
        var bits: [String] = []
        if let state = obj["gateway_state"] as? String { bits.append(state) }
        if let pid = obj["pid"] as? Int { bits.append("pid \(pid)") }
        else if let pid = obj["pid"] as? NSNumber { bits.append("pid \(pid.intValue)") }
        if let platforms = obj["platforms"] as? [String: Any] {
            let names = platforms.keys.sorted()
            for name in names {
                guard let plat = platforms[name] as? [String: Any] else { continue }
                let state = plat["state"] as? String ?? "unknown"
                if let err = plat["error_message"] as? String, !err.isEmpty {
                    bits.append("\(name)=\(state) (\(clip(err)))")
                } else {
                    bits.append("\(name)=\(state)")
                }
            }
        }
        return bits.isEmpty ? "gateway_state.json present but empty" : bits.joined(separator: "; ")
    }

    private static func hermesCronStatus() -> String {
        let url = hermesHome().appendingPathComponent("cron/jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "no ~/.hermes/cron/jobs.json"
        }
        guard let obj = jsonObject(at: url), let jobs = obj["jobs"] as? [[String: Any]] else {
            return "unreadable ~/.hermes/cron/jobs.json"
        }
        if jobs.isEmpty { return "0 jobs" }
        let enabled = jobs.filter { ($0["enabled"] as? Bool) ?? false }.count
        var bits = ["\(enabled)/\(jobs.count) enabled"]
        for job in jobs {
            let name = (job["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (job["id"] as? String)
                ?? "job"
            let status = job["last_status"] as? String ?? "never"
            if let err = job["last_error"] as? String, !err.isEmpty {
                bits.append("\(name): \(status) (\(clip(err)))")
            } else {
                bits.append("\(name): \(status)")
            }
        }
        return bits.joined(separator: "; ")
    }

    private static func homeAssistantStatus() -> String {
        let token = dotenvHasKey("HASS_TOKEN")
        var bits = [token ? "HASS_TOKEN set" : "HASS_TOKEN missing"]
        bits.append(dotenvHasKey("HASS_URL") ? "HASS_URL set" : "HASS_URL default")
        let url = hermesHome().appendingPathComponent("gateway_state.json")
        if let obj = jsonObject(at: url),
           let platforms = obj["platforms"] as? [String: Any],
           let ha = platforms["homeassistant"] as? [String: Any] {
            let state = ha["state"] as? String ?? "unknown"
            if let err = ha["error_message"] as? String, !err.isEmpty {
                bits.append("platform \(state) (\(clip(err)))")
            } else {
                bits.append("platform \(state)")
            }
        } else {
            bits.append("platform not in gateway_state")
        }
        return bits.joined(separator: "; ")
    }

    private static func launchAgentStatus() -> String {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.apple-tasks.dispatch.plist").path
        guard FileManager.default.fileExists(atPath: plist) else {
            return "not installed (run: make install-agent)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.apple-tasks.dispatch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return "plist present, launchctl probe failed"
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return "loaded (com.apple-tasks.dispatch)"
        }
        return "plist present but not loaded (re-run: make install-agent)"
    }

    func run() async throws {
        emit(DoctorOut(
            binary: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path,
            hostProcess: Self.hostProcessName(),
            reminders: Self.describe(EKEventStore.authorizationStatus(for: .reminder)),
            calendars: Self.describe(EKEventStore.authorizationStatus(for: .event)),
            location: LocationFetcher.describeAuthorization(),
            contacts: ContactsAccess.describeAuthorization(),
            foundationModels: LocalClassifier.status(),
            findmySidecar: Self.findmyStatus(),
            mailRule: FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Scripts/com.apple.mail/apple-tasks-capture.scpt").path)
                ? "installed (attach via Mail > Settings > Rules)"
                : "not installed (run: make mail-rule)",
            dropFolder: FileManager.default.fileExists(atPath: Files.defaultDir)
                ? "present: \(Files.defaultDir)"
                : "not created yet: \(Files.defaultDir)",
            privateHelper: Self.helperStatus(),
            notesScanWatermark: ScanState.load().notesScanWatermark,
            speech: Self.speechStatus(),
            fullDiskAccess: Self.fdaStatus(),
            agentsConfig: Self.agentsConfigStatus(),
            cursorAgent: Self.cursorAgentStatus(),
            launchAgent: Self.launchAgentStatus(),
            hermes: Self.hermesStatus(),
            hermesGateway: Self.hermesGatewayStatus(),
            hermesCron: Self.hermesCronStatus(),
            homeAssistant: Self.homeAssistantStatus(),
            budget: Self.budgetStatus(),
            automationNote: "Notes/Mail Apple Events permission cannot be probed without triggering a prompt; run 'apple-tasks notes scan --since <now>' to test."
        ))
    }
}
