import Foundation

public enum BindMode: String, Sendable {
    case tailscale
    case loopback
}

public enum BindError: Error, CustomStringConvertible, Sendable {
    case lanBindRequiresFlag
    case invalidAddress(String)

    public var description: String {
        switch self {
        case .lanBindRequiresFlag:
            return "refusing 0.0.0.0 / wildcard bind without --unsafe-lan-bind"
        case .invalidAddress(let s):
            return "invalid bind address: \(s)"
        }
    }
}

public enum BindResolver {
    /// Resolve the listen host. Never returns a wildcard unless `unsafeLan` is true.
    public static func host(mode: BindMode, explicit: String?, unsafeLan: Bool) throws -> String {
        if let explicit, !explicit.isEmpty {
            if isWildcard(explicit) && !unsafeLan {
                throw BindError.lanBindRequiresFlag
            }
            return explicit
        }
        if unsafeLan {
            throw BindError.lanBindRequiresFlag
        }
        switch mode {
        case .loopback:
            return "127.0.0.1"
        case .tailscale:
            return tailscaleIPv4() ?? "127.0.0.1"
        }
    }

    public static func isWildcard(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "*"
    }

    public static func tailscaleIPv4() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tailscale", "ip", "-4"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ip = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).first.map(String.init)
        guard let ip, ip.contains("."), !isWildcard(ip) else { return nil }
        return ip
    }
}
