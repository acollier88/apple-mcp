import Foundation

/// Caller-based refusals for human-only commands (`secret get|set|rm`,
/// `secret migrate --apply`, `approve answer`).
///
/// This is a **speed bump, not a boundary**: `APPLE_TASKS_CALLER` is an
/// environment variable that a dispatched agent running as the same user
/// can unset or overwrite. It stops the accidental / prompt-injected
/// "just run `apple-tasks secret get …`" path and leaves an audit row; it
/// does not stop an agent determined to read the login Keychain. See
/// docs/security.md §5.
///
/// No TTY requirement: the documented use of `secret get` is shell
/// substitution (`$(apple-tasks secret get x)`), where stdout is a pipe,
/// and a dispatched agent can allocate a pty anyway — a TTY check would
/// break the human path without raising the bar for an agent.
enum CallerGuard {
    static var currentCaller: String? {
        ProcessInfo.processInfo.environment["APPLE_TASKS_CALLER"]
    }

    /// `agent:<tag>` — set by `Dispatch.execute` for dispatched agents.
    static func isDispatchedAgent(_ caller: String?) -> Bool {
        guard let caller else { return false }
        return caller.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("agent:")
    }

    /// `agent:<tag>` or `mcp` (set by mcp/src/lib.ts for every MCP call).
    static func isAutomated(_ caller: String?) -> Bool {
        guard let caller else { return false }
        let normalized = caller.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "mcp" || normalized.hasPrefix("agent:")
    }

    /// Refusal for Keychain secret commands (values in or out, or deletes).
    static func secretRefusal(command: String, caller: String?) -> String? {
        guard isAutomated(caller), let caller else { return nil }
        return "\(command) is for the human user, not automated callers (APPLE_TASKS_CALLER=\(caller)); "
            + "run it from your own terminal"
    }

    /// Refusal for `approve answer`: an agent must not answer approvals.
    static func approvalAnswerRefusal(caller: String?) -> String? {
        guard isDispatchedAgent(caller), let caller else { return nil }
        return "approve answer is not available to dispatched agents (APPLE_TASKS_CALLER=\(caller)); "
            + "the human answers via the ntfy buttons or their own terminal"
    }

    /// Audit the refusal, then throw. Call from `run()` before doing work.
    static func enforce(_ refusal: String?, command: String, detail: String?) throws {
        guard let refusal else { return }
        AuditDB.shared.record(command: command, detail: detail, result: "refused", error: refusal)
        throw AppleTasksError.invalidInput(refusal)
    }
}
