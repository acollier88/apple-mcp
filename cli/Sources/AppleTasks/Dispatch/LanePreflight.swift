import Foundation

/// Pre-claim readiness (#43). A lane that is not ready stays queued: no
/// ledger row and no `[failed]` tag. Auth checks are local (an API key in
/// the environment, or the CLI's own status command). They do not send a
/// prompt, so they are not billed.
enum LanePreflight {
    /// DNS is often down for a short window after boot. Hold claims until then.
    static let bootSettleSeconds: TimeInterval = 120

    enum AuthKind: Equatable {
        case ready
        /// A person has to log in or set a credential. Never a heal task.
        case needsHuman(command: String)
        /// The lane's backend did not answer. Stay queued; this is not a
        /// credential to go hunt for.
        case unreachable(String)
    }

    enum Block: Equatable {
        case bootSettle(uptime: TimeInterval)
        case networkDown
        case authMissing(command: String)
        case backendUnreachable(String)
        case healTarget
    }

    struct Pass: Equatable {
        var uptime: TimeInterval
        var networkUp: Bool
        var authByLane: [String: AuthKind]
    }

    struct CronJob: Equatable {
        var name: String
        var status: String
        var error: String?
    }

    struct Classified: Equatable {
        var signature: String
        var summary: String
        /// Set when a person must run this command. Nil means a heal may try.
        var needsHumanCommand: String?
    }

    static func block(
        uptime: TimeInterval,
        networkUp: Bool,
        auth: AuthKind?,
        isHealTarget: Bool
    ) -> Block? {
        if uptime < bootSettleSeconds {
            return .bootSettle(uptime: uptime)
        }
        if !networkUp { return .networkDown }
        if isHealTarget { return .healTarget }
        switch auth {
        case .needsHuman(let command):
            return .authMissing(command: command)
        case .unreachable(let detail):
            return .backendUnreachable(detail)
        case .ready, nil:
            return nil
        }
    }

    /// Reason string for `laneSkipReason`. The `gated:` prefix keeps the
    /// task queued instead of marking it failed.
    static func skipReason(_ block: Block) -> String {
        switch block {
        case .bootSettle(let uptime):
            return "gated: boot settle (\(Int(uptime))s < \(Int(bootSettleSeconds))s)"
        case .networkDown:
            return "gated: network down"
        case .authMissing(let command):
            return "gated: login missing (\(command))"
        case .backendUnreachable(let detail):
            return "gated: backend unreachable (\(detail))"
        case .healTarget:
            return "gated: heal must not run on the lane it heals"
        }
    }

    /// First agent tag on a `[heal]` task, ignoring `heal` and `auto`.
    /// That lane is the one the task is meant to repair.
    static func healTargetLane(tags: [String], agentNames: Set<String>) -> String? {
        let lower = tags.map { $0.lowercased() }
        guard lower.contains("heal") else { return nil }
        return lower.first { name in
            name != "heal" && name != "auto" && agentNames.contains(name)
        }
    }

    /// When the pinned lane is the one being healed, and a separate `heal`
    /// lane exists, send the task there. Nil means "keep the normal pool".
    static func retargetHealLane(named: String?, healTarget: String?, hasHealLane: Bool) -> String? {
        guard let named, let healTarget, named == healTarget, hasHealLane, healTarget != "heal" else {
            return nil
        }
        return "heal"
    }

    static func interpretAgentStatus(hasAPIKey: Bool, timedOut: Bool, exitCode: Int32, output: String) -> AuthKind {
        if hasAPIKey { return .ready }
        if timedOut { return .unreachable("agent status timed out") }
        // /usr/bin/env exits 127 when the binary is not on PATH. That is an
        // install or PATH problem, not a login to ask the human for.
        if exitCode == 127 { return .unreachable("agent not found on PATH") }
        let flat = output.replacingOccurrences(of: " ", with: "")
        if flat.contains("\"isAuthenticated\":true") { return .ready }
        if flat.contains("\"isAuthenticated\":false") {
            return .needsHuman(command: "agent login")
        }
        if exitCode != 0 { return .needsHuman(command: "agent login") }
        return .unreachable("agent status unreadable")
    }

    static func interpretClaudeAuth(hasAPIKey: Bool, timedOut: Bool, exitCode: Int32, output: String) -> AuthKind {
        if hasAPIKey { return .ready }
        if timedOut { return .unreachable("claude auth status timed out") }
        if exitCode == 127 { return .unreachable("claude not found on PATH") }
        let lower = output.lowercased()
        if lower.contains("not logged") || lower.contains("login required") {
            return .needsHuman(command: "claude auth login")
        }
        if lower.contains("api key:") && !lower.contains("missing") && !lower.contains("none") {
            return .ready
        }
        if lower.contains("logged in") { return .ready }
        if exitCode != 0 {
            return .needsHuman(command: "claude auth login")
        }
        return .unreachable("claude auth status unreadable")
    }

    static func interpretOllama(reachable: Bool) -> AuthKind {
        reachable
            ? .ready
            : .unreachable("ollama-launch not accepting connections on 127.0.0.1:11434")
    }

    /// `blocked_config` / missing provider credentials are per job and need a
    /// person. They are not a heal.
    static func cronBlocked(_ jobs: [CronJob]) -> [Classified] {
        jobs.compactMap { job in
            let blob = "\(job.status) \(job.error ?? "")".lowercased()
            let blocked = blob.contains("blocked_config") || blob.contains("credential")
            guard blocked else { return nil }
            let token = signatureToken(job.name)
            return Classified(
                signature: "hermes-cron-blocked:\(token)",
                summary: "cron \(job.name) is \(job.status)"
                    + (job.error.map { " (\($0))" } ?? ""),
                needsHumanCommand: "hermes config"
            )
        }
    }

    static func laneAuthIssues(authByLane: [String: AuthKind]) -> [Classified] {
        authByLane.keys.sorted().compactMap { lane in
            guard case .needsHuman(let command) = authByLane[lane] else { return nil }
            return Classified(
                signature: "lane-auth-missing:\(signatureToken(lane))",
                summary: "\(lane) is not logged in",
                needsHumanCommand: command
            )
        }
    }

    static func mcpUnavailableIssue(mentioned: Bool) -> Classified? {
        guard mentioned else { return nil }
        return Classified(
            // Distinct from the detector's `mcp-unavailable` (server cannot
            // start): here the server may be fine, the doctor lane fell back.
            signature: "doctor-lane-mcp-fallback",
            summary: "doctor lane logged MCP unavailable and fell back to the CLI",
            needsHumanCommand: nil
        )
    }

    /// Signatures that were not in the last doctor pass. The record is a
    /// newline-separated list; clearing a signature lets it notify again.
    static func signaturesToNotify(previous: String?, issues: [Classified]) -> [Classified] {
        let seen = Set((previous ?? "").split(separator: "\n").map(String.init))
        return issues.filter { issue in
            issue.needsHumanCommand != nil && !seen.contains(issue.signature)
        }
    }

    static func signatureRecord(_ issues: [Classified]) -> String {
        issues.compactMap { $0.needsHumanCommand != nil ? $0.signature : nil }
            .sorted()
            .joined(separator: "\n")
    }

    static func mentionsMCPUnavailable(summary: String?, logTail: String?) -> Bool {
        let blob = "\(summary ?? "")\n\(logTail ?? "")"
        return blob.localizedCaseInsensitiveContains("mcp unavailable")
    }

    private static func signatureToken(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
            return "-"
        }
        let token = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return token.isEmpty ? "job" : token
    }
}

/// Per-pass readiness, probed lazily: uptime and DNS on the first question,
/// each lane's login only when a candidate actually reaches that lane. An
/// idle pass (no due tasks) runs no probes at all.
final class LaneReadiness: @unchecked Sendable {
    private let config: AgentsConfig
    private let env: [String: String]
    private var network: Bool?
    private var auth: [String: LanePreflight.AuthKind] = [:]
    let uptime: TimeInterval

    init(config: AgentsConfig, env: [String: String],
         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.config = config
        self.env = env
        self.uptime = uptime
    }

    var networkUp: Bool {
        if let network { return network }
        let up = LaneProbe.dnsUp()
        network = up
        return up
    }

    func authKind(_ tag: String) async -> LanePreflight.AuthKind? {
        if let cached = auth[tag] { return cached }
        guard let agent = config.agents[tag] else { return nil }
        let kind = await LaneProbe.authKind(tag: tag, agent: agent, env: env)
        auth[tag] = kind
        return kind
    }
}

/// Live probes for one dispatch or doctor pass. Results are classified by
/// `LanePreflight`; this type only runs the commands.
enum LaneProbe {
    static func snapshot(config: AgentsConfig, env: [String: String]) async -> LanePreflight.Pass {
        var auth: [String: LanePreflight.AuthKind] = [:]
        for (tag, agent) in config.agents {
            auth[tag] = await authKind(tag: tag, agent: agent, env: env)
        }
        return LanePreflight.Pass(
            uptime: ProcessInfo.processInfo.systemUptime,
            networkUp: dnsUp(),
            authByLane: auth
        )
    }

    static func authKind(tag: String, agent: AgentsConfig.Agent, env: [String: String]) async -> LanePreflight.AuthKind {
        let argv = agent.commandTemplate(tag: tag) ?? []
        let bin = URL(fileURLWithPath: argv.first ?? "").lastPathComponent.lowercased()
        let provider = AgentSeat.option(argv, "--provider")?.lowercased()
        switch bin {
        case "agent", "cursor-agent":
            let hasKey = !(env["CURSOR_API_KEY"] ?? "").isEmpty
            if hasKey { return .ready }
            let probe = runStatus(binary: "agent", arguments: ["status", "--format", "json"])
            return LanePreflight.interpretAgentStatus(
                hasAPIKey: false, timedOut: probe.timedOut, exitCode: probe.exit, output: probe.output)
        case "claude":
            let hasKey = !(env["ANTHROPIC_API_KEY"] ?? "").isEmpty
            if hasKey { return .ready }
            let probe = runStatus(binary: "claude", arguments: ["auth", "status", "--text"])
            return LanePreflight.interpretClaudeAuth(
                hasAPIKey: false, timedOut: probe.timedOut, exitCode: probe.exit, output: probe.output)
        case "hermes":
            if provider == "ollama-launch" {
                return LanePreflight.interpretOllama(reachable: await ollamaUp())
            }
            return .ready
        default:
            return .ready
        }
    }

    /// True when DNS can resolve a public name. A missing resolver tool does
    /// not block dispatch; a ran-and-failed lookup does.
    static func dnsUp() -> Bool {
        let url = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        guard let run = try? ProcessRunner.run(
            url, ["-q", "host", "-a", "name", "one.one.one.one"], timeout: 3
        ) else { return true }
        if run.timedOut { return false }
        return run.stdoutString.contains("ip_address")
    }

    static func ollamaUp() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/version") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private struct StatusProbe {
        var timedOut: Bool
        var exit: Int32
        var output: String
    }

    /// Runs a status command. Output is for classification only and must not
    /// be logged: `agent status` includes the account email.
    private static func runStatus(binary: String, arguments: [String]) -> StatusProbe {
        let url = URL(fileURLWithPath: "/usr/bin/env")
        // Same PATH rewrite dispatch gives the agents, so a GUI or MCP
        // caller without ~/.local/bin on PATH probes the same binary.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Dispatch.agentSearchPath(existing: env["PATH"])
        guard let run = try? ProcessRunner.run(url, [binary] + arguments, environment: env, timeout: 8) else {
            return StatusProbe(timedOut: false, exit: 127, output: "")
        }
        let output = run.stdoutString + "\n" + run.stderrString
        return StatusProbe(timedOut: run.timedOut, exit: run.status, output: output)
    }
}
