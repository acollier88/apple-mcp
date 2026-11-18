import Foundation

/// An `agent:*` caller may roll a recurring reminder once per dispatch.
/// A second `complete` in that same ledger row is a no-op so the series
/// does not skip an occurrence. Human callers are unchanged.
enum AgentRecurringComplete {
    enum Decision: Equatable {
        case proceed
        case ignore
    }

    static func rolledKey(_ ledgerId: Int) -> String {
        "complete.rolled.\(ledgerId)"
    }

    static func decision(caller: String, hasRecurrence: Bool, alreadyRolled: Bool) -> Decision {
        if caller.hasPrefix("agent:"), hasRecurrence, alreadyRolled {
            return .ignore
        }
        return .proceed
    }
}
