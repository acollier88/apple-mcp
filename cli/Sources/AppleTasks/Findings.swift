import CryptoKit
import Foundation

/// One registry for doctor probes (#52). A detector is a pure function. The
/// class picks the sink: a heal task, a proposal row, or a needs-you notice.
enum Findings {
    enum Kind: String, Equatable {
        case healable
        case proposable
        case needsHuman = "needs-human"
    }

    struct Finding: Equatable {
        var detector: String
        var fingerprint: String
        var system: String
        var severity: String
        var kind: Kind
        var summary: String
        var evidence: String
        var action: String

        var evidenceHash: String {
            SHA256.hash(data: Data(evidence.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        var issue: DoctorIssue {
            DoctorIssue(system: system, severity: severity, summary: summary, signature: fingerprint)
        }
    }

    struct Stored: Equatable {
        var evidenceHash: String
        var state: String
    }

    /// `quiet` means the same evidence was already seen. `refresh` means the
    /// evidence changed, so the sinks may speak again.
    enum Decision: Equatable {
        case open
        case quiet
        case refresh
    }

    static let homeAssistantId = "homeassistant"
    static let hermesId = "hermes"

    static func enabled(_ id: String, _ settings: AgentsConfig.DetectorSettings?) -> Bool {
        if settings?.disabled?.contains(id) == true { return false }
        if let allow = settings?.enabled { return allow.contains(id) }
        return true
    }

    static func homeAssistant(status: String) -> Finding? {
        let down = status.localizedCaseInsensitiveContains("unreachable")
            || status.localizedCaseInsensitiveContains("HASS_TOKEN missing")
            || status.localizedCaseInsensitiveContains("HTTP 401")
            || status.localizedCaseInsensitiveContains("bad HASS_URL")
            || status.localizedCaseInsensitiveContains("probe failed")
        guard down else { return nil }
        return Finding(
            detector: homeAssistantId, fingerprint: homeAssistantId, system: homeAssistantId,
            severity: "red", kind: .healable, summary: status, evidence: status,
            action: "Bring the homeassistant service back, then run apple-tasks doctor.")
    }

    static func hermes(status: String, gateway: String, cron: String, haLink: String, haDown: Bool) -> Finding? {
        var bits: [String] = []
        if status.localizedCaseInsensitiveContains("not installed")
            || status.localizedCaseInsensitiveContains("binary not on PATH") {
            bits.append(status)
        }
        if gateway.localizedCaseInsensitiveContains("not running") {
            bits.append("gateway: \(gateway)")
        }
        if cronIsHealable(cron) {
            bits.append("cron: \(cron)")
        }
        if !haDown, haLink.localizedCaseInsensitiveContains("retrying")
            || haLink.localizedCaseInsensitiveContains("failed")
            || haLink.localizedCaseInsensitiveContains("error") {
            bits.append("haAdapter: \(haLink)")
        }
        guard !bits.isEmpty else { return nil }
        let summary = bits.joined(separator: "; ")
        return Finding(
            detector: hermesId, fingerprint: hermesId, system: hermesId,
            severity: "red", kind: .healable, summary: summary, evidence: summary,
            action: "Repair the Hermes gateway or the failing cron job. Do not restart-loop it while Home Assistant is down.")
    }

    /// Copilot 403 on a job already pinned to ollama-launch is stale.
    static func cronIsHealable(_ cron: String) -> Bool {
        guard cron.localizedCaseInsensitiveContains(": error")
                || cron.localizedCaseInsensitiveContains("last_error") else { return false }
        let staleCopilot = cron.localizedCaseInsensitiveContains("provider=ollama-launch")
            && (cron.localizedCaseInsensitiveContains("403")
                || cron.localizedCaseInsensitiveContains("copilot"))
        if staleCopilot { return false }
        if cron.hasPrefix("no ") || cron.hasPrefix("unreadable") || cron.hasPrefix("0 jobs") {
            return false
        }
        return true
    }

    static func decide(evidenceHash: String, stored: Stored?) -> Decision {
        guard let stored else { return .open }
        if stored.evidenceHash == evidenceHash { return .quiet }
        return .refresh
    }

    /// Whether a healable finding may create a task on this pass.
    static func shouldEnqueue(decision: Decision, createdToday: Int, dailyCap: Int) -> Bool {
        guard decision != .quiet else { return false }
        return createdToday < max(dailyCap, 0)
    }

    enum Sink: String, Equatable {
        case heal
        case proposed
        case needsHuman = "needs-human"
    }

    static func sink(for kind: Kind) -> Sink {
        switch kind {
        case .healable: return .heal
        case .proposable: return .proposed
        case .needsHuman: return .needsHuman
        }
    }
}
