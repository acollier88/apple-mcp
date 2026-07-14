import ArgumentParser
import Foundation

// MARK: - push config (~/.config/apple-tasks/notify.json — never committed)

struct NotifyConfig: Codable {
    struct Ntfy: Codable {
        let topic: String
        /// Defaults to https://ntfy.sh
        let server: String?
    }
    let ntfy: Ntfy?
    /// Quiet hours (IDEAS #43): `{"notBetween": ["22:00", "07:00"]}` — same
    /// shape as the dispatch `time` gate (TimeWindow, ContextGate.swift).
    /// Inside the window `notify` suppresses banner + push (still exits 0);
    /// `--force` overrides for priority pings.
    let quietHours: TimeWindow?
    /// Approvals (IDEAS #39): reply topic the Approve/Deny buttons publish
    /// to. Defaults to "<topic>-approvals". Topics are the secret — keep it
    /// as unguessable as the main topic.
    let approvalsReplyTopic: String?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/notify.json")
    }

    static func load() -> NotifyConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NotifyConfig.self, from: data)
    }
}

enum Notifier {
    /// Local banner via JXA; args passed as argv, never interpolated.
    static func banner(title: String, body: String) {
        let script = """
        function run(argv) {
            const app = Application.currentApplication();
            app.includeStandardAdditions = true;
            app.displayNotification(argv[1], { withTitle: argv[0] });
        }
        """
        _ = try? OSA.runJXA(script, args: [title, body])
    }

    /// ntfy push, best-effort. False when unconfigured or the POST failed.
    @discardableResult
    static func push(title: String, body: String) async -> Bool {
        guard let ntfy = NotifyConfig.load()?.ntfy else { return false }
        let server = ntfy.server ?? "https://ntfy.sh"
        guard let url = URL(string: "\(server)/\(ntfy.topic)") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        // ntfy reads the title from this header; body is the message text.
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.httpBody = Data(body.utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

// MARK: - notify subcommand

struct NotifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Show a macOS notification banner; --push also sends via ntfy so it reaches you off-Mac."
    )

    @Argument(help: "Notification title.")
    var title: String

    @Argument(help: "Notification message.")
    var message: String

    @Flag(help: "Also push via ntfy (config: ~/.config/apple-tasks/notify.json).")
    var push = false

    @Flag(help: "Priority ping: send even during quietHours (notify.json).")
    var force = false

    struct Out: Codable {
        let banner: Bool
        let pushed: Bool
        /// The quiet-hours window ("22:00–07:00") when it suppressed this
        /// notification; absent otherwise.
        let suppressedQuietHours: String?
    }

    func run() async throws {
        // Quiet hours (IDEAS #43): inside the window nothing fires but the
        // command still succeeds — audited so the silence is traceable.
        // Invalid windows fail open: a config typo must not mute pings.
        if !force, let quiet = NotifyConfig.load()?.quietHours,
           case .inside(let window) = quiet.check() {
            AuditDB.shared.record(command: "notify", detail: title,
                                  result: "suppressed (quiet hours \(window))")
            emit(Out(banner: false, pushed: false, suppressedQuietHours: window))
            return
        }
        Notifier.banner(title: title, body: message)
        var pushed = false
        if push {
            pushed = await Notifier.push(title: title, body: message)
            guard pushed else {
                throw AppleTasksError.saveFailed(
                    "push failed or unconfigured; expected {\"ntfy\": {\"topic\": \"...\"}} at \(NotifyConfig.url.path)")
            }
        }
        emit(Out(banner: true, pushed: pushed, suppressedQuietHours: nil))
    }
}
