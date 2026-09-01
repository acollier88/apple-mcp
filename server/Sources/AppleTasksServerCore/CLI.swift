import Foundation

public enum CLIError: Error, CustomStringConvertible, Sendable {
    case binaryMissing(String)
    case timeout([String])
    case failed(Int32, String)

    public var description: String {
        switch self {
        case .binaryMissing(let tried):
            return "apple-tasks binary not found. Tried: \(tried)"
        case .timeout(let args):
            return "timed out running apple-tasks \(args.joined(separator: " "))"
        case .failed(let code, let stderr):
            return "apple-tasks exited \(code): \(stderr)"
        }
    }
}

public enum AppleTasksCLI {
    public static var binary: String {
        get throws {
            var candidates: [String] = []
            if let env = ProcessInfo.processInfo.environment["APPLE_TASKS_BIN"], !env.isEmpty {
                candidates.append(env)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            candidates.append(home.appendingPathComponent(".local/bin/apple-tasks").path)
            let here = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(here.appendingPathComponent("cli/.build/release/apple-tasks").path)
            if let which = which("apple-tasks") { candidates.append(which) }
            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            throw CLIError.binaryMissing(candidates.joined(separator: ", "))
        }
    }

    public static func run(_ args: [String], timeout: TimeInterval) throws -> String {
        let bin = try binary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["APPLE_TASKS_CALLER"] = "apple-tasks-server"
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw CLIError.timeout(args)
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw CLIError.failed(process.terminationStatus, err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
}
