import Foundation

// MARK: - dispatch

struct AgentsConfig: Codable {
    struct Agent: Codable {
        /// Command argv; "{prompt}" is replaced with the rendered prompt.
        /// Optional when `llm` is set (a BYOM lane needs no command).
        let command: [String]?
        /// BYOM (IDEAS #51): an OpenAI-compatible endpoint profile. A lane
        /// with `llm` and no `command` runs the built-in `llm` bridge —
        /// plain completions, no tool use, so it suits classifier seats
        /// (triage) and generate-only tasks.
        let llm: LlmCommand.Profile?
        let promptTemplate: String?
        /// Run in a fresh git worktree of the workdir (output = a branch, not
        /// edits to the main checkout). Requires the workdir to be a git repo.
        let worktree: Bool?
        /// Kill the agent and mark the run 'timeout' after this many minutes.
        let timeoutMinutes: Int?
        /// Max simultaneous runs for THIS agent (default: no per-agent cap).
        let maxConcurrent: Int?
        /// Extra environment variables for the agent process (IDEAS #51) —
        /// endpoint overrides, API keys — merged over the inherited env.
        let env: [String: String]?
        /// How the rendered prompt reaches the agent (default `argv`):
        /// - `argv`: `{prompt}` in `command` is replaced inline (visible in
        ///   `ps`, subject to ARG_MAX, echoed into the ledger's command column).
        /// - `stdin`: the prompt is piped to the process; `{prompt}` entries
        ///   are dropped from argv. Use with `claude -p` / `codex exec -`.
        /// - `file`: the prompt is written to `runs/<ledgerId>.prompt` and
        ///   `{promptFile}` in `command` is replaced with that path.
        /// Both non-argv modes keep a copy at `runs/<ledgerId>.prompt`.
        let promptVia: PromptVia?

        /// The argv template for this lane ({prompt} not yet substituted),
        /// or nil when neither `command` nor `llm` is configured. BYOM lanes
        /// call back into this binary's `llm` bridge with only the tag —
        /// the bridge re-reads agents.json, so keys never hit the argv.
        func commandTemplate(tag: String) -> [String]? {
            if let command { return command }
            guard llm != nil else { return nil }
            return [AgentsConfig.selfBinary, "llm", "--agent", tag, "-p", "{prompt}"]
        }
        /// Context gates (IDEAS #22): all must pass or the task stays queued
        /// (no claim, no [failed]) and is retried next pass.
        let conditions: Conditions?
    }

    enum PromptVia: String, Codable, Sendable {
        case argv, stdin, file
    }

    struct Conditions: Codable {
        /// Named place from `places` this Mac must be within.
        let location: String?
        /// Required power source: "ac" | "battery".
        let power: String?
        /// Skip dispatch while the 1-minute load average exceeds this.
        let maxLoad: Double?
        /// Quiet hours (IDEAS #43): stay queued while local time is inside
        /// `{"notBetween": ["22:00", "07:00"]}` (wraps midnight when
        /// start > end). Same shape as notify's `quietHours`.
        let time: TimeWindow?
        /// Stay queued until the user has been idle (no keyboard/mouse input)
        /// for at least this many minutes (IDEAS #48).
        let idleMinutes: Double?
        /// Stay queued while any of these apps are running. Each entry
        /// matches a bundle id ("us.zoom.xos") or app name ("Keynote"),
        /// case-insensitive exact match (IDEAS #48).
        let blockingApps: [String]?
    }

    struct Place: Codable {
        let lat: Double
        let lon: Double
        /// Geofence radius in meters (default 150).
        let radiusM: Double?
    }

    struct TriageConfig: Codable {
        /// Agent tag in `agents` used as the classifier (default "triage").
        let agent: String?
        /// Reminders list to triage (default "Reminders").
        let inbox: String?
    }

    /// A model seat's default backend (IDEAS #51): "local" for the
    /// on-device model, or any agents.json lane (CLI or BYOM llm).
    struct SeatConfig: Codable {
        let agent: String?
    }

    var agents: [String: Agent]
    /// Named places for `conditions.location` gates.
    var places: [String: Place]?
    /// When present, run a one-shot inbox triage (see Triage.swift) at the
    /// start of every dispatch cycle, before scanning for dispatchable tasks.
    var triage: TriageConfig?
    /// Default backend for the `suggest` seat (also digest --suggest).
    var suggest: SeatConfig?
    /// Max simultaneous agent runs overall (default 1 = v1 sequential behavior).
    var maxConcurrent: Int?
    /// Repo/project tag -> working directory.
    var workdirs: [String: String]?
    /// When true (default), only tasks also tagged [auto] are dispatched.
    var requireAutoTag: Bool?
    /// Re-dispatch [failed] tasks up to this many times (default 0 = never).
    var maxRetries: Int?
    /// Wait this long after the Nth failure before retry N+1 (scales linearly).
    var retryBackoffMinutes: Int?
    /// Keep failed/timeout worktrees this many days before GC (default 7).
    var keepFailedWorktreeDays: Int?
    /// macOS notification on run finish: "failure" (default) | "all" | "none".
    var notifyOn: String?
    /// Hermes-style preference lists (IDEAS #52). `auto` is the ordered pool
    /// for tasks tagged `[auto]` with no matching agent tag. Other keys
    /// (`fast` / `thinking` / `complex`) are reserved for later seats.
    var modelPrefs: [String: [String]]?
    /// How `[auto]`-only routing treats Budget Tracker bandwidth:
    /// `"skipRed"` (default) | `"skipYellow"` | `"off"`. Named lane tags ignore this.
    var autoBudget: String?
    /// Phase A claim-guard mode. `"running"` (today's behavior, the effective
    /// default while this is nil) blocks re-dispatch whenever any
    /// `[dispatched…]` tag is present. `"modified"` additionally compares the
    /// content fingerprint against the last succeeded row and only blocks
    /// when nothing changed — so a human edit or recurrence roll unstrands
    /// a task that an agent left open. Plan is to flip the default to
    /// `"modified"` after a week live.
    var claimGuard: String?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/agents.json")
    }

    /// Path of the running binary, for BYOM lanes to call back into. A bare
    /// argv[0] (PATH lookup) is left as-is — runners exec via /usr/bin/env,
    /// which re-resolves it the same way.
    static var selfBinary: String {
        let arg0 = CommandLine.arguments[0]
        guard arg0.contains("/") else { return arg0 }
        return URL(fileURLWithPath: arg0).standardizedFileURL.path
    }

    static func load() throws -> AgentsConfig {
        guard let data = try? Data(contentsOf: url) else {
            throw AppleTasksError.saveFailed("no agents config at \(url.path); create it to enable dispatch")
        }
        return try JSONDecoder().decode(AgentsConfig.self, from: data)
    }

    static let defaultPromptTemplate = """
    You have been dispatched a task from AgentTasks (Apple Reminders).
    Task id: {id}
    List: {list}
    Title: {title}
    Notes: {notes}
    Do the work described by the task. When finished, record a 1-3 sentence
    outcome summary: apple-tasks update {id} --append-notes "<what you did>"
    If your work produced a PR, commit, or file, link it:
    apple-tasks update {id} --url "<link>"
    then mark it done by running:
    apple-tasks complete {id}
    and remove the dispatched marker: apple-tasks update {id} --remove-tag {claimTag}
    """

    /// Lanes never chosen for `[auto]`-only routing (classifiers / ops).
    static let autoPoolExcluded: Set<String> = ["triage", "local", "doctor", "heal"]

    /// Default walk when `modelPrefs.auto` is absent: local House first, then premium.
    static let autoPoolDefaultOrder = ["hermes", "cursor", "claude", "antigravity"]

    /// Worker lanes that `[auto]` with no provider tag may take, in preference order.
    /// `preferWorktree` puts `worktree: true` lanes first so a repo-tagged task
    /// prefers an isolated coding agent over House (hermes).
    func autoPool(preferWorktree: Bool = false) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let seeds: [String]
        if let listed = modelPrefs?["auto"], !listed.isEmpty {
            seeds = listed
        } else {
            seeds = Self.autoPoolDefaultOrder + agents.keys.sorted()
        }
        for raw in seeds {
            let t = raw.lowercased()
            guard agents[t] != nil,
                  !Self.autoPoolExcluded.contains(t),
                  seen.insert(t).inserted else { continue }
            out.append(t)
        }
        guard preferWorktree else { return out }
        let isolated = out.filter { agents[$0]?.worktree == true }
        let rest = out.filter { agents[$0]?.worktree != true }
        return isolated + rest
    }
}

// IDEAS #13: multi-Mac claim protocol. Tasks sync via iCloud but each Mac
// has its own ledger, so the human-visible claim tags are hostname-scoped
// ([dispatched:mbp]) and a dispatcher only reaps/retries its OWN claims —
// another Mac's [dispatched:x]/[failed:x] is respected as theirs. Bare
// legacy [dispatched]/[failed] tags are treated as this machine's.
enum ClaimTags {
    static let host: String = {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        return sanitizeHost(String(cString: buf))
    }()

    /// First DNS label, lowercased, keeping letters/digits/hyphen. `"mac"` if empty.
    static func sanitizeHost(_ raw: String) -> String {
        let label = raw.split(separator: ".").first.map(String.init) ?? raw
        let cleaned = label.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "mac" : cleaned
    }

    static var dispatched: String { "dispatched:\(host)" }
    static var failed: String { "failed:\(host)" }

    static func isDispatched(_ tag: String) -> Bool {
        let l = tag.lowercased()
        return l == "dispatched" || l.hasPrefix("dispatched:")
    }

    static func isFailed(_ tag: String) -> Bool {
        let l = tag.lowercased()
        return l == "failed" || l.hasPrefix("failed:")
    }

    /// This machine's claim: hostname-scoped or bare legacy.
    static func isOwn(_ tag: String) -> Bool {
        let l = tag.lowercased()
        return l == "dispatched" || l == "failed"
            || l == "dispatched:\(host)" || l == "failed:\(host)"
    }
}

extension Dispatch {
    /// PATH for spawned agents: user install dirs first, then whatever the
    /// parent process had (Terminal may already include them; AgentTasks.app
    /// and launchd usually do not).
    static func agentSearchPath(existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = [
            "\(home)/.local/bin",
            "\(home)/.cursor/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existingParts = (existing ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var parts: [String] = []
        for p in prefix + existingParts + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if seen.insert(p).inserted { parts.append(p) }
        }
        return parts.joined(separator: ":")
    }
}
