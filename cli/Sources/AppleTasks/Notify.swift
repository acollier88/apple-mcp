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

    struct Out: Codable {
        let banner: Bool
        let pushed: Bool
    }

    func run() async throws {
        Notifier.banner(title: title, body: message)
        var pushed = false
        if push {
            pushed = await Notifier.push(title: title, body: message)
            guard pushed else {
                throw AppleTasksError.saveFailed(
                    "push failed or unconfigured; expected {\"ntfy\": {\"topic\": \"...\"}} at \(NotifyConfig.url.path)")
            }
        }
        emit(Out(banner: true, pushed: pushed))
    }
}
