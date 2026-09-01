import AppleTasksServerCore
import Foundation

struct ServeFile: Codable {
    var token: String?
    var port: UInt16?
    var bind: String?
}

@main
struct AppleTasksServerMain {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("-h") || args.contains("--help") {
            fputs("""
            apple-tasks-server [--port N] [--bind tailscale|loopback] [--listen HOST] [--unsafe-lan-bind]
            Auth: APPLE_TASKS_SERVE_TOKEN or ~/.config/apple-tasks/serve.json
            """, stderr)
            return
        }

        let file = loadServeFile()
        let token = ProcessInfo.processInfo.environment["APPLE_TASKS_SERVE_TOKEN"]
            ?? file.token
            ?? ""
        guard !token.isEmpty else {
            fputs("APPLE_TASKS_SERVE_TOKEN or serve.json token is required\n", stderr)
            exit(2)
        }

        let port = parseUInt16(flag: "--port", args: args) ?? file.port ?? 8745
        let bindName = flagValue("--bind", args) ?? file.bind ?? "tailscale"
        let mode = BindMode(rawValue: bindName) ?? .tailscale
        let explicit = flagValue("--listen", args)
        let unsafeLan = args.contains("--unsafe-lan-bind")
        let host = try BindResolver.host(mode: mode, explicit: explicit, unsafeLan: unsafeLan)

        let server = ServeHTTP(config: ServeConfig(host: host, port: port, token: token))
        try server.runForever()
    }

    static func loadServeFile() -> ServeFile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/serve.json")
        guard let data = try? Data(contentsOf: url) else { return ServeFile() }
        return (try? JSONDecoder().decode(ServeFile.self, from: data)) ?? ServeFile()
    }

    static func flagValue(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    static func parseUInt16(flag: String, args: [String]) -> UInt16? {
        flagValue(flag, args).flatMap(UInt16.init)
    }
}
