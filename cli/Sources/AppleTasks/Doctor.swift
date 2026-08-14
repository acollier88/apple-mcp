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
    let hermesHaLink: String
    let homeAssistant: String
    let budget: String
    let automationNote: String
    let issues: [DoctorIssue]
    let heals: HealReport?

    struct PrivateHelperStatus: Codable {
        let present: Bool
        let path: String?
        let check: String?
    }
}

struct DoctorIssue: Codable {
    let system: String
    let severity: String
    let summary: String
    let signature: String
}

struct HealReport: Codable {
    let list: String
    let actions: [HealAction]
}

struct HealAction: Codable {
    let system: String
    let action: String
    let taskId: String?
    let title: String?
    let reason: String?
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report permission and configuration status for THIS host process, plus independent Hermes and Home Assistant healthchecks and Budget Tracker bandwidth. With --enqueue-heals, create [heal] tasks for unhealthy systems so launchd dispatch can run specialist lanes. TCC grants are per-host: Terminal working proves nothing about an MCP host app."
    )

    @Flag(name: .customLong("enqueue-heals"), help: "Create one [heal][auto] task per unhealthy system (deduped). Launchd dispatch picks them up — this command does not spawn agents.")
    var enqueueHeals = false

    @Option(name: .customLong("list"), help: "Reminders list for heal tasks (default: Code Tasks).")
    var listName: String = "Code Tasks"

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

    /// Read a ~/.hermes/.env value. Callers must not emit secrets (HASS_TOKEN, JWT, keys).
    private static func dotenvValue(_ key: String) -> String? {
        let url = hermesHome().appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard t.hasPrefix("\(key)=") else { continue }
            var value = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Host:port only — never query string or userinfo.
    private static func displayOrigin(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else { return "unparseable-url" }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "http")://\(host)\(port)"
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
        let pidValue: Int? = (obj["pid"] as? Int) ?? (obj["pid"] as? NSNumber)?.intValue
        if let pidValue {
            bits.append("pid \(pidValue)")
            if kill(pid_t(pidValue), 0) != 0 {
                bits.append("process not running")
            }
        }
        if let platforms = obj["platforms"] as? [String: Any] {
            let names = platforms.keys.sorted().filter { $0 != "homeassistant" }
            for name in names {
                guard let plat = platforms[name] as? [String: Any] else { continue }
                let state = plat["state"] as? String ?? "unknown"
                if let err = plat["error_message"] as? String, !err.isEmpty {
                    bits.append("\(name)=\(state) (\(clip(err)))")
                } else {
                    bits.append("\(name)=\(state)")
                }
            }
            if platforms["homeassistant"] != nil {
                bits.append("haAdapter=see hermesHaLink")
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
            let provider = (job["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var line = "\(name): \(status)"
            if let provider { line += " provider=\(provider)" }
            if let err = job["last_error"] as? String, !err.isEmpty {
                line += " (\(clip(err)))"
            }
            bits.append(line)
        }
        return bits.joined(separator: "; ")
    }

    /// Hermes gateway's Home Assistant *adapter* only — not HA core health.
    private static func hermesHaLinkStatus() -> String {
        let url = hermesHome().appendingPathComponent("gateway_state.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "unknown (gateway not running)"
        }
        guard let obj = jsonObject(at: url),
              let platforms = obj["platforms"] as? [String: Any],
              let ha = platforms["homeassistant"] as? [String: Any] else {
            return "adapter not in gateway_state"
        }
        let state = ha["state"] as? String ?? "unknown"
        if let err = ha["error_message"] as? String, !err.isEmpty {
            return "\(state) (\(clip(err)))"
        }
        return state
    }

    /// Home Assistant core via HTTP /api/. Independent of the Hermes adapter.
    private static func homeAssistantStatus() -> String {
        let token = dotenvValue("HASS_TOKEN")
        let rawURL = dotenvValue("HASS_URL") ?? "http://homeassistant.local:8123"
        var bits = ["origin \(displayOrigin(rawURL))"]
        bits.append(token == nil ? "HASS_TOKEN missing" : "HASS_TOKEN set")

        guard var api = URL(string: rawURL) else {
            bits.append("unreachable (bad HASS_URL)")
            return bits.joined(separator: "; ")
        }
        if api.path.isEmpty || api.path == "/" {
            api.appendPathComponent("api")
        } else if !api.path.hasSuffix("/api") && !api.path.hasSuffix("/api/") {
            api.appendPathComponent("api")
        }

        var request = URLRequest(url: api, timeoutInterval: 3)
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let sem = DispatchSemaphore(value: 0)
        var probe = "probe failed"
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error {
                probe = "unreachable (\(clip(error.localizedDescription, limit: 80)))"
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                probe = "api ok"
            } else if code == 401 {
                probe = "reachable (HTTP 401 — token rejected)"
            } else {
                probe = "reachable (HTTP \(code))"
            }
            _ = data
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        bits.append(probe)
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
        let hermes = Self.hermesStatus()
        let hermesGateway = Self.hermesGatewayStatus()
        let hermesCron = Self.hermesCronStatus()
        let hermesHaLink = Self.hermesHaLinkStatus()
        let homeAssistant = Self.homeAssistantStatus()
        let issues = Self.collectIssues(
            hermes: hermes,
            hermesGateway: hermesGateway,
            hermesCron: hermesCron,
            hermesHaLink: hermesHaLink,
            homeAssistant: homeAssistant
        )
        var heals: HealReport?
        if enqueueHeals {
            heals = await Self.enqueueHeals(issues: issues, listName: listName)
        }
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
            hermes: hermes,
            hermesGateway: hermesGateway,
            hermesCron: hermesCron,
            hermesHaLink: hermesHaLink,
            homeAssistant: homeAssistant,
            budget: Self.budgetStatus(),
            automationNote: "Notes/Mail Apple Events permission cannot be probed without triggering a prompt; run 'apple-tasks notes scan --since <now>' to test.",
            issues: issues,
            heals: heals
        ))
    }

    /// One issue per affected *system*. Hermes↔HA adapter is ignored when HA itself is down.
    static func collectIssues(
        hermes: String,
        hermesGateway: String,
        hermesCron: String,
        hermesHaLink: String,
        homeAssistant: String
    ) -> [DoctorIssue] {
        var issues: [DoctorIssue] = []
        let haDown = homeAssistant.localizedCaseInsensitiveContains("unreachable")
            || homeAssistant.localizedCaseInsensitiveContains("HASS_TOKEN missing")
            || homeAssistant.localizedCaseInsensitiveContains("HTTP 401")
            || homeAssistant.localizedCaseInsensitiveContains("bad HASS_URL")
            || homeAssistant.localizedCaseInsensitiveContains("probe failed")
        if haDown {
            issues.append(DoctorIssue(
                system: "homeassistant",
                severity: "red",
                summary: homeAssistant,
                signature: "homeassistant"
            ))
        }

        var hermesBits: [String] = []
        if hermes.localizedCaseInsensitiveContains("not installed")
            || hermes.localizedCaseInsensitiveContains("binary not on PATH") {
            hermesBits.append(hermes)
        }
        if hermesGateway.localizedCaseInsensitiveContains("not running") {
            hermesBits.append("gateway: \(hermesGateway)")
        }
        if let cronIssue = Self.cronHealSummary(hermesCron) {
            hermesBits.append(cronIssue)
        }
        if !haDown, hermesHaLink.localizedCaseInsensitiveContains("retrying")
            || hermesHaLink.localizedCaseInsensitiveContains("failed")
            || hermesHaLink.localizedCaseInsensitiveContains("error") {
            hermesBits.append("haAdapter: \(hermesHaLink)")
        }
        if !hermesBits.isEmpty {
            issues.append(DoctorIssue(
                system: "hermes",
                severity: "red",
                summary: hermesBits.joined(separator: "; "),
                signature: "hermes"
            ))
        }

        let failed = AuditDB.shared.dispatchRows(status: "failed", limit: 20)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        let recent = failed.filter { row in
            if row.agent == "doctor" { return false }
            let stamp = row.finishedAt ?? row.startedAt
            let date = iso.date(from: stamp) ?? isoBasic.date(from: stamp)
            guard let date else { return true }
            return date >= cutoff
        }
        if !recent.isEmpty {
            let lines = recent.prefix(8).map { row in
                "#\(row.id) \(row.agent) \(row.summary ?? row.status)"
            }
            issues.append(DoctorIssue(
                system: "dispatch",
                severity: "yellow",
                summary: lines.joined(separator: "; "),
                signature: "dispatch"
            ))
        }
        return issues
    }

    /// Copilot 403 on a job already pinned to ollama-launch is stale, not a heal.
    private static func cronHealSummary(_ cron: String) -> String? {
        guard cron.localizedCaseInsensitiveContains(": error")
                || cron.localizedCaseInsensitiveContains("last_error") else {
            return nil
        }
        let staleCopilot = cron.localizedCaseInsensitiveContains("provider=ollama-launch")
            && (cron.localizedCaseInsensitiveContains("403")
                || cron.localizedCaseInsensitiveContains("copilot"))
        if staleCopilot { return nil }
        if cron.hasPrefix("no ") || cron.hasPrefix("unreadable") || cron.hasPrefix("0 jobs") {
            return nil
        }
        return "cron: \(cron)"
    }

    private static func enqueueHeals(issues: [DoctorIssue], listName: String) async -> HealReport {
        guard !issues.isEmpty else {
            return HealReport(list: listName, actions: [])
        }
        let store = Store()
        do {
            try await store.requestAccess()
        } catch {
            let reason = (error as? AppleTasksError)?.description ?? error.localizedDescription
            return HealReport(list: listName, actions: issues.map {
                HealAction(system: $0.system, action: "skipped", taskId: nil, title: nil, reason: reason)
            })
        }
        let open = (await store.reminders(in: nil)).filter { !$0.isCompleted }
        var actions: [HealAction] = []
        for issue in issues {
            let spec = Self.healSpec(issue)
            if let existing = open.first(where: { Self.isOpenHeal($0, signature: issue.signature) }) {
                let parsed = Tags.parse(existing.title ?? "")
                actions.append(HealAction(
                    system: issue.system,
                    action: "exists",
                    taskId: existing.calendarItemExternalIdentifier ?? existing.calendarItemIdentifier,
                    title: parsed.title,
                    reason: "open heal already queued"
                ))
                continue
            }
            do {
                let out = try createTask(
                    store: store,
                    listName: listName,
                    title: spec.title,
                    tags: spec.tags,
                    notes: spec.notes,
                    due: nil,
                    priority: .high,
                    url: nil,
                    recurrence: nil,
                    mirrorNativeTags: true,
                    auditCommand: "doctor-heal"
                )
                actions.append(HealAction(
                    system: issue.system,
                    action: "created",
                    taskId: out.id,
                    title: out.title,
                    reason: nil
                ))
            } catch {
                let reason = (error as? AppleTasksError)?.description ?? error.localizedDescription
                actions.append(HealAction(
                    system: issue.system,
                    action: "skipped",
                    taskId: nil,
                    title: spec.title,
                    reason: reason
                ))
            }
        }
        return HealReport(list: listName, actions: actions)
    }

    private static func isOpenHeal(_ reminder: EKReminder, signature: String) -> Bool {
        let tags = Set(Tags.parse(reminder.title ?? "").tags.map { $0.lowercased() })
        guard tags.contains("heal") else { return false }
        let notes = reminder.notes ?? ""
        if notes.contains("heal-signature: \(signature)") { return true }
        return tags.contains(signature.lowercased())
    }

    private struct HealSpec {
        let tags: [String]
        let title: String
        let notes: String
    }

    private static func healSpec(_ issue: DoctorIssue) -> HealSpec {
        let header = "heal-signature: \(issue.signature)\n\nHome Doctor found: \(issue.summary)\n\n"
        let footer = """

Never toggle Home Assistant entities (lights, climate, locks, covers). Never print tokens or .env values. Do not call dispatch_run (recursive dispatch is blocked). Launchd will not re-dispatch this task until you complete it.
When finished: apple-tasks update <id> --append-notes "<what you did>" then apple-tasks complete <id> and apple-tasks update <id> --remove-tag dispatched:\(ClaimTags.host)
"""
        switch issue.system {
        case "homeassistant":
            return HealSpec(
                tags: ["heal", "home-lab", "auto"],
                title: "Heal Home Assistant API",
                notes: header + """
HA is the `homeassistant` Docker service in ~/Documents/home-lab/compose.yaml (port 8123).
cd ~/Documents/home-lab && docker compose ps && docker compose up -d
Re-probe with apple-tasks doctor. If HASS_URL is the wrong origin, set it in ~/.hermes/.env (do not print or rotate HASS_TOKEN) and restart the Hermes gateway (`hermes gateway run --replace`).
""" + footer
            )
        case "hermes":
            return HealSpec(
                tags: ["hermes", "heal", "auto"],
                title: "Heal Hermes",
                notes: header + """
Hermes-side: start or replace the gateway (`hermes gateway run --replace` or the argv in ~/.hermes/gateway_state.json). If a cron job last_error is Copilot 403 and the job is not already --provider ollama-launch, pin provider ollama-launch and model qwen3.6-35b. Do not restart-loop the gateway while Home Assistant is down.
""" + footer
            )
        default:
            return HealSpec(
                tags: ["heal", "apple-mcp", "auto"],
                title: "Heal failed apple-tasks dispatches",
                notes: header + """
Inspect apple-tasks dispatches --status failed and the run log under ~/.config/apple-tasks/runs/. Fix the underlying failure (config, workdir tag, agent binary) so the next launchd pass can succeed. Do not re-dispatch this doctor pass.
""" + footer
            )
        }
    }
}
