import CryptoKit
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
    let jev: String
    let findmySidecar: String
    let mailRule: String
    let dropFolder: String
    let privateHelper: PrivateHelperStatus
    let notesScanWatermark: String?
    let speech: String
    let fullDiskAccess: String
    let agentsConfig: String
    let secrets: [SecretStatus]
    let cursorAgent: String
    let launchAgent: String
    let hermes: String
    let hermesGateway: String
    let hermesCron: String
    let hermesHaLink: String
    let homeAssistant: String
    let budget: String
    let deployment: DeploymentStatus
    let dispatch: DispatchPauseInfo
    let automationNote: String
    let issues: [DoctorIssue]
    let heals: HealReport?
    /// Gatehouse probe. Missing gatehouse fills this in; it does not fail doctor.
    let gatehouse: GatehouseDoctorStatus
    /// Retention windows, what `runs/` and the ledger occupy, oldest kept log (#70).
    let retention: Retention.Status
    /// Today's claims against `limits`, and whether `stop --all` is in force (#68).
    let limits: Limits.Status
    /// `--fix-modes` only: every chmod it made beyond the secret files
    /// (config dir, ledger DB/WAL/SHM, logs/, runs/*, agents.json[.bak-*]).
    let fixedModes: [ConfigPermissions.ModeChange]?

    struct DispatchPauseInfo: Codable {
        let paused: Bool
        let until: String?
        let reason: String?
    }

    struct PrivateHelperStatus: Codable {
        let present: Bool
        let path: String?
        let check: String?
    }

    /// Which binary launchd actually runs, and whether its source tree has
    /// drifted from it (uncommitted edits, or a HEAD newer than the build).
    struct DeploymentStatus: Codable {
        let launchdBinary: String?
        /// Commit stamped into the launchd binary (`apple-tasks --version`);
        /// nil for an unstamped build (plain `swift build`, pre-#33).
        let launchdCommit: String?
        let binaryModified: String?
        let sourceTree: String?
        let sourceHead: String?
        let sourceDirty: Bool?
        /// Commit comparison: true when the launchd binary carries the same
        /// cli/ code as HEAD. nil when it could not be compared.
        let binaryMatchesHead: Bool?
        /// mtime fallback, only set when `comparison` is "mtime".
        let binaryOlderThanCliCommit: Bool?
        /// "commit" | "mtime" | "none" — which check produced the verdict.
        let comparison: String
        let note: String
    }
}

struct SecretStatus: Codable {
    let name: String
    /// `SecretSource` raw value: env | keychain | plaintext | missing
    let source: String
    let file: String?
    /// Octal like "644"
    let mode: String?
    let note: String?
}

struct DoctorIssue {
    let system: String
    let severity: String
    let summary: String
    let signature: String
    /// When set, a person has to run this command. Never enqueue a heal for it.
    var needsHumanCommand: String? = nil
    /// `healable` or `needs-human`. Nil keeps the pre-#47 enqueue behavior.
    var kind: String? = nil
    var evidence: String? = nil
    var suggestedAction: String? = nil

    init(system: String, severity: String, summary: String, signature: String,
         needsHumanCommand: String? = nil,
         kind: String? = nil, evidence: String? = nil, suggestedAction: String? = nil) {
        self.system = system
        self.severity = severity
        self.summary = summary
        self.signature = signature
        self.needsHumanCommand = needsHumanCommand
        self.kind = kind
        self.evidence = evidence
        self.suggestedAction = suggestedAction
    }
}

extension DoctorIssue: Codable {
    enum CodingKeys: String, CodingKey {
        case system, severity, summary, signature, needsHumanCommand, kind, evidence, suggestedAction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decode(String.self, forKey: .system)
        severity = try c.decode(String.self, forKey: .severity)
        summary = try c.decode(String.self, forKey: .summary)
        signature = try c.decode(String.self, forKey: .signature)
        needsHumanCommand = try c.decodeIfPresent(String.self, forKey: .needsHumanCommand)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        suggestedAction = try c.decodeIfPresent(String.self, forKey: .suggestedAction)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(system, forKey: .system)
        try c.encode(severity, forKey: .severity)
        try c.encode(summary, forKey: .summary)
        try c.encode(signature, forKey: .signature)
        try c.encodeIfPresent(needsHumanCommand, forKey: .needsHumanCommand)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(evidence, forKey: .evidence)
        try c.encodeIfPresent(suggestedAction, forKey: .suggestedAction)
    }
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

    @Flag(name: .customLong("fix-modes"), help: "Tighten modes: config dir, logs/, runs/ to 700; secret files, ledger DB/WAL/SHM, logs/*, runs/*, agents.json(.bak-*) to 600. Reports changes in fixedModes.")
    var fixModes = false

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

    /// Per-secret audit: env → keychain → plaintext → missing. Never includes values.
    static func secretsStatus(configDir: URL, store: SecretStore, env: [String: String],
                              fixModes: Bool) -> [SecretStatus] {
        let notifyURL = configDir.appendingPathComponent("notify.json")
        let serveURL = configDir.appendingPathComponent("serve.json")
        let llmURL = configDir.appendingPathComponent("llm.json")
        let credentialsURL = configDir.appendingPathComponent("gmail/credentials.json")
        let tokenURL = configDir.appendingPathComponent("gmail/token.json")
        let launchdURL = configDir.appendingPathComponent("launchd.env")
        let agentsURL = configDir.appendingPathComponent("agents.json")

        let notifyFile = auditFile(notifyURL, fixModes: fixModes)
        let serveFile = auditFile(serveURL, fixModes: fixModes)
        let llmFile = auditFile(llmURL, fixModes: fixModes)
        let credentialsFile = auditFile(credentialsURL, fixModes: fixModes)
        let tokenFile = auditFile(tokenURL, fixModes: fixModes)
        let launchdFile = auditFile(launchdURL, fixModes: fixModes)
        let agentsFile = auditFile(agentsURL, fixModes: fixModes)

        var rows: [SecretStatus] = []

        let notify = (try? Data(contentsOf: notifyURL)).flatMap {
            try? JSONDecoder().decode(NotifyConfig.self, from: $0)
        }
        let topicSource = resolveSource(
            envName: Secrets.ntfyTopicEnv, itemName: Secrets.ntfyTopic,
            plaintext: notify?.ntfy?.topic, store: store, env: env)
        rows.append(status(name: Secrets.ntfyTopic, source: topicSource, file: notifyFile))
        let replyExplicit = resolveSource(
            envName: Secrets.ntfyApprovalsReplyTopicEnv,
            itemName: Secrets.ntfyApprovalsReplyTopic,
            plaintext: notify?.approvalsReplyTopic, store: store, env: env)
        // No derived fallback since #28: missing means approvals over ntfy are off.
        rows.append(status(name: Secrets.ntfyApprovalsReplyTopic, source: replyExplicit, file: notifyFile))

        let servePlain: String? = {
            guard let data = try? Data(contentsOf: serveURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty else { return nil }
            return token
        }()
        rows.append(status(
            name: Secrets.serveToken,
            source: resolveSource(envName: Secrets.serveTokenEnv, itemName: Secrets.serveToken,
                                  plaintext: servePlain, store: store, env: env),
            file: serveFile))

        rows.append(status(
            name: Secrets.gmailClientSecret,
            source: resolveSource(envName: Secrets.gmailClientSecretEnv,
                                  itemName: Secrets.gmailClientSecret,
                                  plaintext: gmailFileSecret(at: credentialsURL),
                                  store: store, env: env),
            file: credentialsFile))

        let gmailTokenSource: SecretSource = {
            if let value = try? store.get(Secrets.gmailToken), !value.isEmpty {
                return .keychain
            }
            if FileManager.default.fileExists(atPath: tokenURL.path) { return .plaintext }
            return .missing
        }()
        rows.append(status(name: Secrets.gmailToken, source: gmailTokenSource, file: tokenFile))

        if let data = try? Data(contentsOf: llmURL),
           let file = try? JSONDecoder().decode(LlmCommand.ConfigFile.self, from: data) {
            for name in file.profiles.keys.sorted() {
                let profile = file.profiles[name]!
                let item = profile.apiKeyKeychain ?? Secrets.llmApiKey(profile: name)
                rows.append(status(
                    name: Secrets.llmApiKey(profile: name),
                    source: resolveSource(envName: profile.apiKeyEnv, itemName: item,
                                          plaintext: profile.apiKey, store: store, env: env),
                    file: llmFile))
            }
        }

        for (name, _) in launchdEnvExports(at: launchdURL) {
            rows.append(status(
                name: "launchd.env:\(name)",
                source: .plaintext,
                file: launchdFile))
        }

        if let data = try? Data(contentsOf: agentsURL),
           let cfg = try? JSONDecoder().decode(AgentsConfig.self, from: data) {
            let hasEnv = cfg.agents.values.contains { ($0.env?.isEmpty == false) }
            if hasEnv {
                rows.append(status(name: "agents.json:env", source: .plaintext, file: agentsFile))
            }
        }

        return rows
    }

    private struct FileAudit {
        let exists: Bool
        let path: String
        let mode: String?
        let modeNote: String?
    }

    private static func auditFile(_ url: URL, fixModes: Bool) -> FileAudit {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileAudit(exists: false, path: url.path, mode: nil, modeNote: nil)
        }
        let before = posixMode(url)
        var modeNote: String?
        if let before, isGroupWorldReadable(before) {
            if fixModes {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
                modeNote = "fixed to 600"
            } else {
                modeNote = "mode \(before), expected 600"
            }
        }
        return FileAudit(exists: true, path: url.path, mode: posixMode(url), modeNote: modeNote)
    }

    private static func posixMode(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let num = attrs[.posixPermissions] as? NSNumber else { return nil }
        return String(num.intValue & 0o777, radix: 8)
    }

    private static func isGroupWorldReadable(_ mode: String) -> Bool {
        guard let value = Int(mode, radix: 8) else { return false }
        return (value & 0o044) != 0
    }

    private static func resolveSource(envName: String?, itemName: String?, plaintext: String?,
                                      store: SecretStore, env: [String: String]) -> SecretSource {
        if let envName, !envName.isEmpty, let value = env[envName], !value.isEmpty {
            return .env
        }
        if let itemName, let value = try? store.get(itemName), !value.isEmpty {
            return .keychain
        }
        if let plaintext, !plaintext.isEmpty {
            return .plaintext
        }
        return .missing
    }

    private static func status(name: String, source: SecretSource, file: FileAudit) -> SecretStatus {
        var notes: [String] = []
        if let modeNote = file.modeNote { notes.append(modeNote) }
        if source == .plaintext {
            notes.append("plaintext — move with: apple-tasks secret migrate --apply")
        }
        return SecretStatus(
            name: name,
            source: source.rawValue,
            file: file.exists ? file.path : nil,
            mode: file.mode,
            note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    private static func gmailFileSecret(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let installed = obj["installed"] as? [String: Any],
           let secret = installed["client_secret"] as? String, !secret.isEmpty {
            return secret
        }
        if let secret = obj["client_secret"] as? String, !secret.isEmpty {
            return secret
        }
        return nil
    }

    private static func launchdEnvExports(at url: URL) -> [(name: String, value: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard t.hasPrefix("export ") else { continue }
            t = String(t.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty, !value.isEmpty else { continue }
            out.append((name, value))
        }
        return out
    }

    private struct PreflightReport {
        var issues: [DoctorIssue]
        var classified: [LanePreflight.Classified]
        var cursorAuth: LanePreflight.AuthKind?
        /// One probe per lane per doctor run; the lane-auth detector reuses it.
        var authByLane: [String: LanePreflight.AuthKind]
    }

    /// Credential and auth failures that `doctor` already had the evidence
    /// for, plus a dead MCP fallback on the doctor lane (#43).
    private static func preflightIssues() async -> PreflightReport {
        let env = ProcessInfo.processInfo.environment
        let config = try? AgentsConfig.load()
        let authByLane: [String: LanePreflight.AuthKind]
        if let config {
            authByLane = (await LaneProbe.snapshot(config: config, env: env)).authByLane
        } else {
            authByLane = [:]
        }
        var classified = LanePreflight.cronBlocked(Self.hermesCronJobs())
        classified += LanePreflight.laneAuthIssues(authByLane: authByLane)
        if let mcp = LanePreflight.mcpUnavailableIssue(mentioned: Self.doctorMentionedMCPUnavailable()) {
            classified.append(mcp)
        }
        // Lane logins and scheduled-job blocks are reported as issues by the
        // detector registry (lane-auth-missing:*, scheduled-blocked:*); here
        // they only drive the one-time "Needs you" push. The doctor-lane MCP
        // fallback has no detector, so it stays an issue.
        let issues = classified.filter {
            !$0.signature.hasPrefix("lane-auth-missing:") && !$0.signature.hasPrefix("hermes-cron-blocked:")
        }.map { item in
            DoctorIssue(
                system: item.signature == "doctor-lane-mcp-fallback" ? "mcp" : "dispatch",
                severity: item.needsHumanCommand == nil ? "yellow" : "notice",
                summary: item.summary,
                signature: item.signature,
                needsHumanCommand: item.needsHumanCommand)
        }
        return PreflightReport(
            issues: issues, classified: classified, cursorAuth: authByLane["cursor"],
            authByLane: authByLane)
    }

    private static func hermesCronJobs() -> [LanePreflight.CronJob] {
        let url = hermesHome().appendingPathComponent("cron/jobs.json")
        guard let obj = jsonObject(at: url), let jobs = obj["jobs"] as? [[String: Any]] else {
            return []
        }
        return jobs.map { job in
            let name = (job["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (job["id"] as? String)
                ?? "job"
            return LanePreflight.CronJob(
                name: name,
                status: job["last_status"] as? String ?? "never",
                error: (job["last_error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Last doctor run logs, not the whole ledger. The phrase is detected;
    /// the log text is not copied into the issue.
    private static func doctorMentionedMCPUnavailable() -> Bool {
        let rows = AuditDB.shared.dispatchRows(status: nil, limit: 40)
            .filter { $0.agent == "doctor" }
        for row in rows.prefix(5) {
            let tail = row.runLogPath.flatMap { path -> String? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      !data.isEmpty else { return nil }
                let start = data.index(data.endIndex, offsetBy: -16_384, limitedBy: data.startIndex) ?? data.startIndex
                return String(data: data[start...], encoding: .utf8)
            }
            if LanePreflight.mentionsMCPUnavailable(summary: row.summary, logTail: tail) {
                return true
            }
        }
        return false
    }

    /// Resolve a binary on PATH the same way dispatch does (/usr/bin/env).
    private static func which(_ name: String) -> String? {
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/env"), ["which", name], timeout: 5),
              result.status == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Resolve `agent` (Cursor Agent CLI) on PATH the same way dispatch does (/usr/bin/env).
    private static func cursorAgentStatus(auth: LanePreflight.AuthKind?) -> String {
        guard let path = which("agent") else {
            return "not found (install: curl https://cursor.com/install -fsS | bash)"
        }
        let login: String
        switch auth {
        case .ready, nil:
            login = "login ok"
        case .needsHuman(let command):
            login = "login missing (run \(command))"
        case .unreachable(let detail):
            login = "login check failed (\(detail))"
        }
        return "present: \(path) (tag tasks [cursor][auto]; \(login))"
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

    /// stdout of a short-lived process, or nil if it failed to launch / exited non-zero.
    private static func capture(_ exe: String, _ args: [String]) -> String? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: exe), args, timeout: 15),
              !result.timedOut, result.status == 0 else { return nil }
        return result.stdoutString
    }

    /// Detects the two-trees hazard: the launchd job runs a binary built from
    /// a checkout that may carry uncommitted edits or lag its own HEAD.
    static func deploymentStatus() -> DoctorOut.DeploymentStatus {
        var launchdBinary: String?
        if let out = capture("/bin/launchctl", ["print", "gui/\(getuid())/com.apple-tasks.dispatch"]),
           let start = out.range(of: "arguments = {") {
            let block = out[start.upperBound...].prefix { $0 != "}" }
            launchdBinary = block.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasSuffix("/apple-tasks") }
        }
        guard let bin = launchdBinary else {
            return .init(launchdBinary: nil, launchdCommit: nil, binaryModified: nil, sourceTree: nil,
                         sourceHead: nil, sourceDirty: nil, binaryMatchesHead: nil,
                         binaryOlderThanCliCommit: nil, comparison: "none",
                         note: "launchd dispatch not loaded; nothing to compare")
        }
        return deploymentStatus(binary: bin, sourceTreeHint: BuildInfo.sourceRoot)
    }

    /// Compare `binary` with its source checkout (#33). Preferred: the commit
    /// stamped into the binary vs HEAD, which tells a stale build from one
    /// made off another branch. Fallback for unstamped binaries: mtime vs the
    /// last cli/ commit. The checkout is found by walking up from the binary
    /// (pre-#33 builds ran from cli/.build), else `sourceTreeHint` (the stamp
    /// of the binary running doctor — usually the same install), else by
    /// walking up from this binary.
    static func deploymentStatus(binary bin: String, sourceTreeHint: String?) -> DoctorOut.DeploymentStatus {
        let iso = ISO8601DateFormatter()
        let binaryDate = (try? FileManager.default.attributesOfItem(atPath: bin))?[.modificationDate] as? Date
        let launchdCommit = capture(bin, ["--version"]).flatMap(BuildInfo.commit(fromVersionOutput:))

        func checkout(above path: URL) -> String? {
            var dir = path.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                    return dir.path
                }
                dir = dir.deletingLastPathComponent()
            }
            return nil
        }
        let hint = sourceTreeHint.flatMap {
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(".git").path)
                ? $0 : nil
        }
        guard let tree = checkout(above: URL(fileURLWithPath: bin)) ?? hint ?? checkout(above: Executable.url) else {
            return .init(launchdBinary: bin, launchdCommit: launchdCommit,
                         binaryModified: binaryDate.map(iso.string), sourceTree: nil, sourceHead: nil,
                         sourceDirty: nil, binaryMatchesHead: nil, binaryOlderThanCliCommit: nil,
                         comparison: "none", note: "no source checkout found to compare against")
        }
        let gitArgs = ["-c", "core.fsmonitor=false", "-C", tree]
        func git(_ args: String...) -> String? {
            capture("/usr/bin/git", gitArgs + args)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = git("rev-parse", "--short=12", "HEAD")
        let dirty = git("status", "--porcelain").map { !$0.isEmpty }

        var notes: [String] = []
        if dirty == true { notes.append("source tree has uncommitted changes — commit or they exist only on this Mac") }
        let redeploy = "run make install (from the checkout you want live)"

        if let launchdCommit {
            let builtDirty = launchdCommit.hasSuffix("-dirty")
            let base = builtDirty ? String(launchdCommit.dropLast("-dirty".count)) : launchdCommit
            var matches: Bool
            if git("rev-parse", "--verify", "--quiet", "\(base)^{commit}") == nil {
                matches = false
                notes.append("binary built from \(base), which this checkout does not have — \(redeploy)")
            } else if git("rev-parse", "\(base)^{commit}") == git("rev-parse", "HEAD") {
                matches = true
            } else if git("merge-base", "--is-ancestor", base, "HEAD") != nil {
                // Behind HEAD; only cli/ changes matter (docs-only commits don't).
                matches = git("diff", "--quiet", base, "HEAD", "--", "cli") != nil
                if !matches { notes.append("binary (\(base)) is behind HEAD (\(head ?? "?")) in cli/ — \(redeploy)") }
            } else {
                matches = false
                notes.append("binary built from \(base), not in HEAD's history (another branch?) — \(redeploy)")
            }
            if builtDirty {
                matches = false
                notes.append("binary was built from uncommitted cli/ changes on top of \(base)")
            }
            return .init(launchdBinary: bin, launchdCommit: launchdCommit,
                         binaryModified: binaryDate.map(iso.string), sourceTree: tree, sourceHead: head,
                         sourceDirty: dirty, binaryMatchesHead: matches, binaryOlderThanCliCommit: nil,
                         comparison: "commit",
                         note: notes.isEmpty ? "ok: launchd runs a build of HEAD's cli/ (\(base))"
                             : notes.joined(separator: "; "))
        }

        // Unstamped binary: mtime vs the last commit touching cli/ (a
        // docs-only commit must not flag a current binary). Cannot tell a
        // stale build from a branch build — hence the stamp.
        let headEpoch = git("log", "-1", "--format=%ct", "--", "cli").flatMap { Double($0) }
        var older: Bool?
        if let binaryDate, let headEpoch {
            older = binaryDate.timeIntervalSince1970 < headEpoch
        }
        if older == true { notes.append("binary predates the last cli/ commit — \(redeploy)") }
        notes.append("binary has no build stamp (mtime comparison only); make install stamps it")
        return .init(launchdBinary: bin, launchdCommit: nil, binaryModified: binaryDate.map(iso.string),
                     sourceTree: tree, sourceHead: head, sourceDirty: dirty, binaryMatchesHead: nil,
                     binaryOlderThanCliCommit: older, comparison: "mtime",
                     note: notes.joined(separator: "; "))
    }

    func run() async throws {
        let hermes = Self.hermesStatus()
        let hermesGateway = Self.hermesGatewayStatus()
        let hermesCron = Self.hermesCronStatus()
        let hermesHaLink = Self.hermesHaLinkStatus()
        let homeAssistant = Self.homeAssistantStatus()
        let pause = Dispatch.resolvedPause(db: .shared)
        let dispatchInfo = DoctorOut.DispatchPauseInfo(
            paused: pause != nil, until: pause?.untilISO, reason: pause?.reason)
        let configDir: URL = {
            if let override = ProcessInfo.processInfo.environment["APPLE_TASKS_CONFIG_DIR"],
               !override.isEmpty {
                return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                           isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/apple-tasks", isDirectory: true)
        }()
        // Doctor only reports. The runtime layout migration (worktrees/,
        // scratch/, runs/ -> Application Support) runs from `dispatch`, which
        // knows whether an agent is using those directories.
        let layout = AppleTasksLayout.resolve()
        let supportDir = layout.support
        let fixedModes = fixModes ? ConfigPermissions.fixModes(configDir: configDir, supportDir: supportDir) : nil
        let secrets = Self.secretsStatus(
            configDir: configDir,
            store: Secrets.store,
            env: ProcessInfo.processInfo.environment,
            fixModes: fixModes)
        var issues = Self.collectIssues(
            hermes: hermes,
            hermesGateway: hermesGateway,
            hermesCron: hermesCron,
            hermesHaLink: hermesHaLink,
            homeAssistant: homeAssistant,
            settings: (try? AgentsConfig.load())?.doctor?.detectors
        )
        let registry = Self.registryFindings(
            hermes: hermes, hermesGateway: hermesGateway, hermesCron: hermesCron,
            hermesHaLink: hermesHaLink, homeAssistant: homeAssistant,
            settings: (try? AgentsConfig.load())?.doctor?.detectors)
        var findingDecisions: [String: String] = [:]
        for finding in registry {
            findingDecisions[finding.fingerprint] = AuditDB.shared.observeFinding(
                fingerprint: finding.fingerprint, detector: finding.detector,
                system: finding.system, severity: finding.severity,
                findingClass: finding.kind.rawValue, summary: finding.summary,
                evidence: finding.evidence, evidenceHash: finding.evidenceHash,
                action: finding.action)
        }
        if let pause, let issue = Self.pauseIssue(pause) {
            issues.append(issue)
        }
        let loadedConfig = try? AgentsConfig.load()
        let preflight = await Self.preflightIssues()
        let findings = await DiagnosticsLive.findings(config: loadedConfig, laneAuth: preflight.authByLane)
        issues.append(contentsOf: findings.map(\.issue))
        // One findings table (#52): detector findings are recorded beside the
        // Home Assistant / Hermes ones, with the same quiet-until-evidence-
        // changes rule, and anything no longer detected is closed.
        for finding in findings {
            let detector = finding.signature.split(separator: ":").first.map(String.init) ?? finding.signature
            let hash = SHA256.hash(data: Data(finding.evidence.utf8)).map { String(format: "%02x", $0) }.joined()
            findingDecisions[finding.signature] = AuditDB.shared.observeFinding(
                fingerprint: finding.signature, detector: detector,
                system: finding.system, severity: finding.severity,
                findingClass: finding.kind.rawValue, summary: finding.summary,
                evidence: finding.evidence, evidenceHash: hash,
                action: finding.suggestedAction)
        }
        for closed in AuditDB.shared.resolveFindings(notSeen: Set(findingDecisions.keys)) {
            HealPolicy.clear(closed)  // a clean detector resets the escalation ladder
        }
        if let loaded = loadedConfig {
            let launchdNames = Self.launchdEnvExports(
                at: configDir.appendingPathComponent("launchd.env")).map(\.name)
            for finding in AgentEnv.exposureFindings(
                config: loaded, launchdNames: launchdNames,
                parentNames: Set(ProcessInfo.processInfo.environment.keys)) {
                issues.append(DoctorIssue(
                    system: "env", severity: "yellow",
                    summary: finding.summary, signature: finding.signature))
            }
        }
        let plaintextCount = secrets.filter { $0.source == SecretSource.plaintext.rawValue }.count
        if plaintextCount > 0 {
            issues.append(DoctorIssue(
                system: "secrets",
                severity: "info",
                summary: "\(plaintextCount) secret(s) in plaintext; run apple-tasks secret migrate --apply",
                signature: "secrets-plaintext"))
        }
        issues.append(contentsOf: preflight.issues)
        issues.append(contentsOf: ProposalsInbox.mutedIssues())
        let beats = Watchdog.directory()
        for notice in Watchdog.notices(
            dispatcher: Watchdog.read(role: "dispatcher", from: beats),
            watchdog: Watchdog.read(role: "watchdog", from: beats),
            now: Date(),
            deadRunning: Watchdog.liveDeadRunningCount(),
            maxPass: Watchdog.maxPassSeconds(config: loadedConfig),
            watchdogInstalled: Watchdog.watchdogInstalled()) {
            issues.append(DoctorIssue(
                system: "watchdog", severity: "info",
                summary: Watchdog.summary(notice),
                signature: Watchdog.signature(notice)))
        }
        // One issue per signature: the first source wins.
        var seenSignatures = Set<String>()
        issues = issues.filter { seenSignatures.insert($0.signature).inserted }
        let previous = AuditDB.shared.getState("doctor.needsHuman")
        for item in LanePreflight.signaturesToNotify(previous: previous, issues: preflight.classified) {
            guard let command = item.needsHumanCommand else { continue }
            _ = await Notifier.push(
                title: "Needs you",
                body: "\(item.summary). Run: \(command)")
        }
        _ = AuditDB.shared.setState("doctor.needsHuman", LanePreflight.signatureRecord(preflight.classified))
        var heals: HealReport?
        if enqueueHeals, Limits.stopped() != nil {
            // Kill switch (#68): no heal tasks and no playbooks while stopped.
            heals = HealReport(list: listName, actions: [
                HealAction(system: "dispatch", action: "skipped", taskId: nil, title: nil,
                           reason: Limits.stoppedReason),
            ])
        } else if enqueueHeals {
            heals = await Self.enqueueHeals(
                issues: issues, listName: listName, config: loadedConfig,
                decisions: findingDecisions, findings: registry)
        }
        emit(DoctorOut(
            binary: Executable.url.path,
            hostProcess: Self.hostProcessName(),
            reminders: Self.describe(EKEventStore.authorizationStatus(for: .reminder)),
            calendars: Self.describe(EKEventStore.authorizationStatus(for: .event)),
            location: LocationFetcher.describeAuthorization(),
            contacts: ContactsAccess.describeAuthorization(),
            foundationModels: LocalClassifier.status(),
            jev: JevClassifier.status(config: (try? AgentsConfig.load())?.jev),
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
            secrets: secrets,
            cursorAgent: Self.cursorAgentStatus(auth: preflight.cursorAuth),
            launchAgent: Self.launchAgentStatus(),
            hermes: hermes,
            hermesGateway: hermesGateway,
            hermesCron: hermesCron,
            hermesHaLink: hermesHaLink,
            homeAssistant: homeAssistant,
            budget: Self.budgetStatus(),
            deployment: Self.deploymentStatus(),
            dispatch: dispatchInfo,
            automationNote: "Notes/Mail Apple Events permission cannot be probed without triggering a prompt; run 'apple-tasks notes scan --since <now>' to test.",
            issues: issues,
            heals: heals,
            gatehouse: Self.gatehouseStatus(),
            retention: Retention.status(
                policy: .init((try? AgentsConfig.load())?.retention),
                runs: layout.runs, ledger: AuditDB.url),
            limits: Limits.status(limits: loadedConfig?.limits,
                                  lanes: Array((loadedConfig?.agents ?? [:]).keys)),
            fixedModes: fixedModes
        ))
    }

    /// Running / enrolled / hooks fail-closed / lanes that are still unsandboxed.
    /// `AgentsConfig.load` failure leaves the lane list empty; the probe itself
    /// never throws.
    static func gatehouseStatus() -> GatehouseDoctorStatus {
        let agents = (try? AgentsConfig.load())?.agents ?? [:]
        return GatehouseClient.doctorStatus(agents: agents, facts: GatehouseClient.observe())
    }

    /// One issue per affected *system*. Hermes↔HA adapter is ignored when HA itself is down.
    static func collectIssues(
        hermes: String,
        hermesGateway: String,
        hermesCron: String,
        hermesHaLink: String,
        homeAssistant: String,
        settings: AgentsConfig.DetectorSettings? = nil
    ) -> [DoctorIssue] {
        var issues = registryFindings(
            hermes: hermes, hermesGateway: hermesGateway, hermesCron: hermesCron,
            hermesHaLink: hermesHaLink, homeAssistant: homeAssistant, settings: settings
        ).map(\.issue)
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
        // Needs a person, not a heal agent: severity info is skipped by enqueueHeals.
        if let maxRetries = (try? AgentsConfig.load())?.maxRetries, maxRetries > 0 {
            let exhausted = AuditDB.shared.retriesExhausted(maxRetries: maxRetries)
            if !exhausted.isEmpty {
                let lines = exhausted.map { "\($0.taskId) (\($0.count) since last success)" }
                issues.append(DoctorIssue(
                    system: "dispatch",
                    severity: "info",
                    summary: "retries exhausted: " + lines.joined(separator: "; ")
                        + ". Raise maxRetries or run dispatch-retry. Do not hunt for credentials.",
                    signature: "retries-exhausted"))
            }
        }
        return issues
    }

    static func registryFindings(
        hermes: String,
        hermesGateway: String,
        hermesCron: String,
        hermesHaLink: String,
        homeAssistant: String,
        settings: AgentsConfig.DetectorSettings? = nil
    ) -> [Findings.Finding] {
        var found: [Findings.Finding] = []
        if Findings.enabled(Findings.homeAssistantId, settings),
           let ha = Findings.homeAssistant(status: homeAssistant) {
            found.append(ha)
        }
        let haDown = Findings.homeAssistant(status: homeAssistant) != nil
        if Findings.enabled(Findings.hermesId, settings),
           let hermesFinding = Findings.hermes(
            status: hermes, gateway: hermesGateway, cron: hermesCron,
            haLink: hermesHaLink, haDown: haDown) {
            found.append(hermesFinding)
        }
        return found
    }

    static func pauseIssue(_ pause: Dispatch.PauseState) -> DoctorIssue? {
        var summary = "dispatcher paused until \(pause.untilISO)"
        if let reason = pause.reason { summary += " (\(reason))" }
        return DoctorIssue(system: "dispatch", severity: "info",
                           summary: summary, signature: "dispatch-pause")
    }

    private static func enqueueHeals(issues: [DoctorIssue], listName: String,
                                     config: AgentsConfig?,
                                     decisions: [String: String] = [:],
                                     findings: [Findings.Finding] = []) async -> HealReport {
        guard !issues.isEmpty else {
            return HealReport(list: listName, actions: [])
        }
        let limits = Diagnostics.thresholds(config?.doctor?.detectors)
        let cooldown = TimeInterval(limits.healCooldownHours) * 3600
        let now = Date()
        var healState = loadHealState()
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
            if issue.needsHumanCommand != nil {
                actions.append(HealAction(
                    system: issue.system,
                    action: "needs-human",
                    taskId: nil,
                    title: nil,
                    reason: issue.needsHumanCommand
                ))
                continue
            }
            // info/notice never become heal tasks (secrets-plaintext is info).
            if issue.severity == "info" || issue.severity == "notice" { continue }
            if issue.system == "secrets" { continue }
            if decisions[issue.signature] == "quiet" {
                actions.append(HealAction(
                    system: issue.system, action: "unchanged", taskId: nil, title: nil,
                    reason: "evidence unchanged"))
                continue
            }
            if let finding = findings.first(where: { $0.fingerprint == issue.signature }) {
                switch Findings.sink(for: finding.kind) {
                case .needsHuman:
                    let sent = await Notifier.push(title: "apple-tasks needs you", body: finding.action)
                    actions.append(HealAction(
                        system: issue.system, action: "needs-human", taskId: nil, title: nil,
                        reason: sent ? finding.action : "notification failed: \(finding.action)"))
                    continue
                case .proposed:
                    actions.append(HealAction(
                        system: issue.system, action: "proposed", taskId: nil, title: nil,
                        reason: finding.action))
                    continue
                case .heal:
                    break
                }
            }
            if issue.kind == Diagnostics.Kind.needsHuman.rawValue {
                actions.append(HealAction(
                    system: issue.system, action: "needs-human", taskId: nil, title: nil,
                    reason: issue.suggestedAction ?? issue.summary))
                continue
            }
            // Ladder (#54, #55): playbook -> agent heal -> needs-human, one rung
            // per piece of evidence. The rung used is remembered per finding
            // and cleared when the detector comes back clean.
            let todayCount = healState.day == Diagnostics.dayString(now) ? healState.count : 0
            switch HealPolicy.decide(
                fingerprint: issue.signature,
                rung: Playbooks.rung(for: issue.signature),
                previous: HealPolicy.level(issue.signature),
                evidenceChanged: decisions[issue.signature] != "quiet",
                healsToday: todayCount,
                cap: limits.healDailyCap) {
            case .quiet:
                actions.append(HealAction(
                    system: issue.system, action: "unchanged", taskId: nil, title: nil,
                    reason: "heal rung already used for this evidence"))
                continue
            case .playbook(let id):
                let steps = Playbooks.plan(
                    await Playbooks.liveContext(config: config, store: store), only: issue.signature)
                var applied: [String] = []
                var failure: String?
                for step in steps where step.apply != .none {
                    do {
                        try await Playbooks.apply(step, store: store)
                        applied.append(step.summary)
                    } catch {
                        failure = (error as? AppleTasksError)?.description ?? error.localizedDescription
                        break
                    }
                }
                HealPolicy.remember(.playbook(id), fingerprint: issue.signature)
                if !applied.isEmpty {
                    healState = Diagnostics.marked(healState, signature: issue.signature, now: now)
                    saveHealState(healState)
                }
                // Verify (#55): only a clean re-check counts as healed.
                var verified = false
                if failure == nil, !applied.isEmpty {
                    let recheck = await DiagnosticsLive.findings(config: config)
                    verified = !recheck.contains { $0.signature == issue.signature }
                    if verified {
                        _ = AuditDB.shared.setFindingState(fingerprint: issue.signature, state: "healed")
                        HealPolicy.clear(issue.signature)
                    }
                }
                actions.append(HealAction(
                    system: issue.system,
                    action: failure != nil ? "playbook-failed" : (verified ? "playbook-verified" : "playbook"),
                    taskId: nil, title: nil,
                    reason: failure.map { "\(id): \($0)" }
                        ?? (applied.isEmpty ? "\(id): nothing to apply"
                            : "\(id): " + applied.joined(separator: "; ")
                                + (verified ? " (re-check clean)" : " (still detected; next rung on new evidence)"))))
                continue
            case .needsHuman(let id):
                HealPolicy.remember(.needsHuman(id), fingerprint: issue.signature)
                let sent = await Notifier.push(
                    title: "apple-tasks needs you",
                    body: "\(issue.summary) Automatic healing stopped for \(id).")
                actions.append(HealAction(
                    system: issue.system, action: "needs-human", taskId: nil, title: nil,
                    reason: sent ? id : "notification failed: \(id)"))
                continue
            case .breaker:
                let day = HealPolicy.dayStamp()
                if AuditDB.shared.getState(HealPolicy.breakerKey) != day {
                    _ = await Notifier.push(
                        title: "apple-tasks needs you",
                        body: "Automatic healing is paused for today (\(limits.healDailyCap) heals).")
                    _ = AuditDB.shared.setState(HealPolicy.breakerKey, day)
                }
                actions.append(HealAction(
                    system: issue.system, action: "paused", taskId: nil, title: nil,
                    reason: "heal circuit breaker"))
                continue
            case .agent:
                break
            }
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
            switch Diagnostics.gate(signature: issue.signature, now: now, state: healState,
                                    cooldown: cooldown, dailyCap: limits.healDailyCap) {
            case .cooldown:
                actions.append(HealAction(
                    system: issue.system, action: "cooldown", taskId: nil, title: spec.title,
                    reason: "heal for \(issue.signature) was enqueued within \(limits.healCooldownHours)h"))
                continue
            case .capped:
                actions.append(HealAction(
                    system: issue.system, action: "capped", taskId: nil, title: spec.title,
                    reason: "daily heal cap \(limits.healDailyCap) already reached"))
                continue
            case .enqueue:
                break
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
                healState = Diagnostics.marked(healState, signature: issue.signature, now: now)
                saveHealState(healState)
                actions.append(HealAction(
                    system: issue.system,
                    action: "created",
                    taskId: out.id,
                    title: out.title,
                    reason: nil
                ))
                HealPolicy.remember(.agent, fingerprint: issue.signature)
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

    private static func loadHealState() -> Diagnostics.HealLedgerState {
        let iso = ISO8601DateFormatter()
        var last: [String: Date] = [:]
        if let raw = AuditDB.shared.getState("doctor.heal.last"),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, value) in obj {
                if let date = iso.date(from: value) { last[key] = date }
            }
        }
        return Diagnostics.HealLedgerState(
            lastEnqueued: last,
            day: AuditDB.shared.getState("doctor.heal.day") ?? "",
            count: Int(AuditDB.shared.getState("doctor.heal.count") ?? "") ?? 0)
    }

    private static func saveHealState(_ state: Diagnostics.HealLedgerState) {
        let iso = ISO8601DateFormatter()
        let obj = Dictionary(uniqueKeysWithValues: state.lastEnqueued.map { ($0.key, iso.string(from: $0.value)) })
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let text = String(data: data, encoding: .utf8) {
            _ = AuditDB.shared.setState("doctor.heal.last", text)
        }
        _ = AuditDB.shared.setState("doctor.heal.day", state.day)
        _ = AuditDB.shared.setState("doctor.heal.count", String(state.count))
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
        if issue.kind == Diagnostics.Kind.healable.rawValue, let action = issue.suggestedAction {
            let evidence = issue.evidence ?? issue.summary
            return HealSpec(
                tags: ["heal", "apple-mcp", "auto"],
                title: "Heal \(issue.system): \(issue.signature)",
                notes: header + """
Evidence:
\(evidence)

Allowed scope: \(action)
Do not look for credentials, tokens, SSH keys, or .env files. If the fix needs a login or a permission prompt, stop and leave this task for a person.
""" + footer)
        }
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
Inspect apple-tasks dispatches --status failed and the run log under ~/Library/Application Support/apple-tasks/runs/. Fix the underlying failure (config, workdir tag, agent binary) so the next launchd pass can succeed. Do not re-dispatch this doctor pass.
""" + footer
            )
        }
    }
}
