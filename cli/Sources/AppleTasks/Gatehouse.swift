import Foundation

/// What a local probe saw. Built without throwing. Tests construct this
/// directly so they never launch `gate` or read the real home directory.
struct GatehouseProbeFacts: Equatable {
    var statusCode: Int32?
    var statusStdout: String = ""
    /// Bodies of passkey files that existed and were readable.
    var passkeyJSON: [Data] = []
    /// Text of a hooks marker file, when one was readable.
    var hooksText: String?
    /// `~/.gatehouse/run/ctl.sock` (or `$GATEHOUSE_RUNTIME_DIR/ctl.sock`) exists.
    var ctlSocketExists: Bool = false
    /// Text of the host gatehouse `policy.toml`, when one was readable.
    var policyText: String? = nil
}

/// Doctor's gatehouse report. Missing gatehouse is these fields, not an error.
struct GatehouseDoctorStatus: Codable, Equatable {
    let running: Bool
    let passkeyEnrolled: Bool
    let hooksFailClosed: Bool
    let unsandboxedLanes: [String]
    /// The host policy has the shipped `__approve_strong` ask_strong rule.
    /// Without it `approve request` keeps the ntfy/CLI path.
    var strongApprovalPolicy: Bool = false
    let note: String
}

/// Detection and the `gate ask` delegation used by `approve request`.
///
/// Running: `gate status` prints the gatehoused status line (exit 0), or the
/// control socket from gatehouse's runtime dir exists. Enrolled: a non-empty
/// JSON array in `passkeys.json` / `passkeys-phone.json` under the gatehouse
/// data dir (`GATEHOUSE_DATA_DIR`, else Application Support, else
/// `~/.local/share/gatehouse` as the README's data path). Hooks fail-closed:
/// a hooks file sets `fail_closed = true` (the shipped `gate hook` adapter
/// returns "ask" when the broker is down, which is not fail-closed).
enum GatehouseClient {
    static func daemonRunning(_ facts: GatehouseProbeFacts) -> Bool {
        if facts.statusCode == 0 {
            let stdout = facts.statusStdout
            if stdout.contains("gatehoused") || stdout.contains("pending approvals") {
                return true
            }
        }
        return facts.ctlSocketExists
    }

    static func passkeyEnrolled(_ facts: GatehouseProbeFacts) -> Bool {
        for data in facts.passkeyJSON {
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], !arr.isEmpty {
                return true
            }
        }
        return false
    }

    /// True only when a hooks file explicitly opts into fail-closed.
    static func hooksFailClosed(_ facts: GatehouseProbeFacts) -> Bool {
        guard let text = facts.hooksText else { return false }
        let compact = text.lowercased().filter { !$0.isWhitespace && $0 != "_" }
        return compact.contains("failclosed=true") || compact.contains("\"failclosed\":true")
    }

    /// Delegate only when the decision would really be ask_strong: daemon up,
    /// passkey enrolled, and the host policy carries the `__approve_strong`
    /// ask_strong rule. Without that rule the argv falls to a plain "ask",
    /// which any local `gate approve` caller (an agent included) can answer.
    static func delegatesApprovals(_ facts: GatehouseProbeFacts) -> Bool {
        daemonRunning(facts) && passkeyEnrolled(facts) && strongApprovalPolicy(facts)
    }

    /// A `[[rules]]` block in the host policy that names `__approve_strong`
    /// and has tier `ask_strong`.
    static func strongApprovalPolicy(_ facts: GatehouseProbeFacts) -> Bool {
        guard let text = facts.policyText else { return false }
        let blocks = text.components(separatedBy: "[[rules]]").dropFirst()
        return blocks.contains { block in
            let body = block.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            let compact = body.filter { !$0.isWhitespace }
            return compact.contains("__approve_strong") && compact.contains("tier=\"ask_strong\"")
        }
    }

    static func doctorStatus(agents: [String: AgentsConfig.Agent],
                              facts: GatehouseProbeFacts) -> GatehouseDoctorStatus {
        let running = daemonRunning(facts)
        let enrolled = passkeyEnrolled(facts)
        let failClosed = hooksFailClosed(facts)
        let strongPolicy = strongApprovalPolicy(facts)
        let unsandboxed = agents.keys.filter { agents[$0]?.sandbox?.isGatehouse != true }.sorted()
        var notes: [String] = []
        if !running {
            notes.append("gatehouse not detected (gate status did not report a running daemon)")
        } else if !enrolled {
            notes.append("gatehoused is running; no passkey enrolled (gate enroll)")
        } else {
            notes.append("gatehoused is running and a passkey is enrolled")
        }
        if running && enrolled && !strongPolicy {
            notes.append("host policy has no __approve_strong ask_strong rule (merge examples/gatehouse/apple-tasks-policy.toml); approvals stay on ntfy/CLI")
        }
        if !failClosed {
            notes.append("hooks are not fail-closed (shipped gate hook returns ask when the broker is unreachable; set fail_closed = true in gatehouse hooks.toml)")
        }
        if !unsandboxed.isEmpty {
            notes.append("unsandboxed lanes: \(unsandboxed.joined(separator: ", "))")
        }
        return GatehouseDoctorStatus(
            running: running,
            passkeyEnrolled: enrolled,
            hooksFailClosed: failClosed,
            unsandboxedLanes: unsandboxed,
            strongApprovalPolicy: strongPolicy,
            note: notes.joined(separator: "; "))
    }

    /// `nil` leaves the approval pending (timeout, gate missing, or an
    /// unexpected exit). `approved` / `denied` match `gate ask` exit 0 / 2.
    static func interpretAsk(code: Int32, timedOut: Bool) -> String? {
        if timedOut { return nil }
        switch code {
        case 0: return "approved"
        case 2: return "denied"
        default: return nil
        }
    }

    /// Live probe. Never throws. Does not run during unit tests unless a test
    /// calls it; doctor and `approve request` are the callers.
    static func observe(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> GatehouseProbeFacts {
        var facts = GatehouseProbeFacts()
        if let gate = gateExecutable(home: home),
           let result = try? ProcessRunner.run(
            gate,
            ["status"],
            environment: env,
            timeout: 3
        ) {
            facts.statusCode = result.status
            facts.statusStdout = result.stdoutString
        }
        let socket = ctlSocketPath(env: env, home: home)
        facts.ctlSocketExists = FileManager.default.fileExists(atPath: socket)
        for url in passkeyURLs(env: env, home: home) {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                facts.passkeyJSON.append(data)
            }
        }
        for url in policyURLs(env: env, home: home) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                facts.policyText = text
                break
            }
        }
        for url in hooksURLs(env: env, home: home) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                facts.hooksText = text
                break
            }
        }
        return facts
    }

    static func ctlSocketPath(env: [String: String], home: URL) -> String {
        let root: URL
        if let raw = env["GATEHOUSE_RUNTIME_DIR"], !raw.isEmpty {
            root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            root = home.appendingPathComponent(".gatehouse/run", isDirectory: true)
        }
        return root.appendingPathComponent("ctl.sock").path
    }

    static func passkeyURLs(env: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let raw = env["GATEHOUSE_DATA_DIR"], !raw.isEmpty {
            roots.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true))
        }
        roots.append(home.appendingPathComponent("Library/Application Support/gatehouse", isDirectory: true))
        roots.append(home.appendingPathComponent(".local/share/gatehouse", isDirectory: true))
        return roots.flatMap {
            [$0.appendingPathComponent("passkeys.json"), $0.appendingPathComponent("passkeys-phone.json")]
        }
    }

    /// Same roots as `hooksURLs`: `$GATEHOUSE_CONFIG_DIR`, then Application Support.
    static func policyURLs(env: [String: String], home: URL) -> [URL] {
        hooksURLs(env: env, home: home).map {
            $0.deletingLastPathComponent().appendingPathComponent("policy.toml")
        }
    }

    static func hooksURLs(env: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let raw = env["GATEHOUSE_CONFIG_DIR"], !raw.isEmpty {
            roots.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true))
        }
        roots.append(home.appendingPathComponent("Library/Application Support/gatehouse", isDirectory: true))
        return roots.map { $0.appendingPathComponent("hooks.toml") }
    }

    /// `gate` from fixed install locations, never from `PATH`: the caller of
    /// `approve request` is usually the agent, which controls its own PATH
    /// and could otherwise put a `gate` that always exits 0 in front.
    static func gateExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gate",
            "/usr/local/bin/gate",
            home.appendingPathComponent(".cargo/bin/gate").path,
            home.appendingPathComponent(".local/bin/gate").path,
        ]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Blocks until `gate ask` returns, or `timeout`. The argv is the one the
    /// shipped policy fragment marks `ask_strong`. A missing `gate` binary
    /// yields nil (the row stays pending). Run from the detached
    /// `approve gate-wait` process, not from the agent's own call.
    static func askStrong(token: String, question: String, timeout: TimeInterval) -> String? {
        guard let gate = gateExecutable() else { return nil }
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                gate,
                ["ask", "--json", "--", "apple-tasks", "__approve_strong", token, question],
                timeout: max(timeout, 1))
        } catch {
            return nil
        }
        return interpretAsk(code: result.status, timedOut: result.timedOut)
    }

    /// State key marking an approval whose only valid answer is gatehouse's.
    static func channelKey(_ token: String) -> String { "approval.channel.\(token)" }
}
