import Foundation

/// Environment handed to spawned agents (dispatch lanes and classifier /
/// suggest seats). Issue #27: by default every agent inherited the
/// dispatcher's whole environment, including API keys sourced from
/// `launchd.env`. `envMode` lets a lane narrow that.
///
/// This reduces what a prompt-injected agent can read from its own
/// environment. It is not a sandbox: the agent still has the user's home
/// directory, login Keychain and the dispatcher's TCC grants.
enum AgentEnv {
    enum Mode: String, Codable, Sendable {
        /// Everything the dispatcher has (pre-#27 behaviour; the default).
        case inherit
        /// Drop variables whose NAME looks secret (`isSecretName`) unless the
        /// lane lists them in `envPassthrough`.
        case scrubSecrets
        /// Only `baseAllowlist` plus `envPassthrough`.
        case allowlist
    }

    /// Resolved per-lane policy; value-typed so it can ride in a RunSpec.
    struct Policy: Sendable, Equatable {
        var mode: Mode = .inherit
        /// Names copied from the dispatcher's environment regardless of mode.
        var passthrough: [String] = []
        /// Lane `env` values; always applied last (they are explicit).
        var overlay: [String: String] = [:]

        /// Lane `envMode`, else top-level `envMode`, else `inherit`. A BYOM
        /// lane's `llm.apiKeyEnv` is passed through implicitly: the spawned
        /// `apple-tasks llm` bridge reads that variable itself.
        static func resolve(lane: AgentsConfig.Agent?, config: AgentsConfig?) -> Policy {
            var names = lane?.envPassthrough ?? []
            if let keyEnv = lane?.llm?.apiKeyEnv, !keyEnv.isEmpty, !names.contains(keyEnv) {
                names.append(keyEnv)
            }
            return Policy(mode: lane?.envMode ?? config?.envMode ?? .inherit,
                          passthrough: names,
                          overlay: lane?.env ?? [:])
        }
    }

    /// Variables kept in `allowlist` mode even when the lane names nothing.
    /// `APPLE_TASKS_CONFIG_DIR` / `APPLE_TASKS_PRIVATE_BIN` are included so an
    /// agent's own `apple-tasks` calls hit the same config as the dispatcher.
    static let baseAllowlist: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "TERM",
        "APPLE_TASKS_CONFIG_DIR", "APPLE_TASKS_PRIVATE_BIN",
    ]

    /// Name fragments that mark a variable as secret-looking (case-insensitive).
    /// Same family as the MCP display redaction in `mcp/src/resources.ts`.
    static let secretNameFragments = ["key", "token", "secret", "password", "passwd", "credential"]

    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretNameFragments.contains { lower.contains($0) }
    }

    static func isBaseAllowed(_ name: String) -> Bool {
        baseAllowlist.contains(name) || name.hasPrefix("LC_")
    }

    /// Pure: the environment for one agent process.
    /// Order: filter `parent` by mode (passthrough names always survive when
    /// present) → lane `env` overlay → `APPLE_TASKS_CALLER` (when `caller`
    /// is given) → PATH rewrite (when `searchPath` is given).
    static func build(parent: [String: String], policy: Policy,
                      caller: String? = nil,
                      searchPath: ((String?) -> String)? = nil) -> [String: String] {
        let passthrough = Set(policy.passthrough)
        var env: [String: String]
        switch policy.mode {
        case .inherit:
            env = parent
        case .scrubSecrets:
            env = parent.filter { passthrough.contains($0.key) || !isSecretName($0.key) }
        case .allowlist:
            env = parent.filter { passthrough.contains($0.key) || isBaseAllowed($0.key) }
        }
        for (name, value) in policy.overlay { env[name] = value }
        if let caller { env["APPLE_TASKS_CALLER"] = caller }
        if let searchPath { env["PATH"] = searchPath(env["PATH"]) }
        return env
    }

    /// Names present in `parent` that `build` would drop (for reporting; values never included).
    static func droppedNames(parent: [String: String], policy: Policy) -> [String] {
        let kept = build(parent: parent, policy: Policy(mode: policy.mode, passthrough: policy.passthrough))
        return parent.keys.filter { kept[$0] == nil }.sorted()
    }
}
