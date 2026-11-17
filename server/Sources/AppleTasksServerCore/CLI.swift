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

    /// Run the CLI and return stdout. `executable` overrides the resolved
    /// binary (tests point it at /bin/sh; production callers omit it).
    public static func run(_ args: [String], timeout: TimeInterval,
                           executable: String? = nil) throws -> String {
        let bin = try executable ?? binary
        var env = ProcessInfo.processInfo.environment
        env["APPLE_TASKS_CALLER"] = "apple-tasks-server"
        let result = try ChildProcess.run(bin, args, environment: env, timeout: timeout)
        if result.timedOut {
            throw CLIError.timeout(args)
        }
        if result.status != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw CLIError.failed(result.status, err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private static func which(_ name: String) -> String? {
        guard let result = try? ChildProcess.run("/usr/bin/env", ["which", name], timeout: 5),
              !result.timedOut, result.status == 0 else { return nil }
        let path = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
}

/// Runs a child while draining stdout and stderr concurrently (#34). The old
/// runner polled `isRunning` and read the pipes only after exit, so any CLI
/// response over the pipe buffer (~64 KB) blocked the child in write() until
/// the timeout and the bridge answered 502. Mirrors the CLI package's
/// `ProcessRunner` (separate SwiftPM package, so it cannot be shared):
/// deadline, SIGTERM then SIGKILL, always reaped.
enum ChildProcess {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval,
                    killGrace: TimeInterval = 2) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let outBox = Buffer()
        let errBox = Buffer()
        let drains = DispatchGroup()
        drain(outPipe.fileHandleForReading, into: outBox, group: drains)
        drain(errPipe.fileHandleForReading, into: errBox, group: drains)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        process.waitUntilExit()
        // A grandchild holding the pipe open must not extend the request.
        _ = drains.wait(timeout: .now() + 2)
        return Result(status: process.terminationStatus, stdout: outBox.data,
                      stderr: errBox.data, timedOut: timedOut)
    }

    private static func drain(_ handle: FileHandle, into box: Buffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            // Raw read(2): FileHandle.read(upToCount:) waits for the full
            // count or EOF, which loses partial output when a grandchild
            // keeps the pipe open past the child's exit.
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    box.append(Data(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
