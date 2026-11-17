import Darwin
import Foundation

/// Outcome of a child process run by `ProcessRunner`.
struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// True when the deadline passed and the child was killed (SIGTERM, then
    /// SIGKILL). `status` is then the signal-terminated status.
    let timedOut: Bool

    var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}

/// The one way the CLI should run a short-lived child and capture its output
/// (#34). Waiting for exit before reading deadlocks as soon as the child
/// writes more than the pipe buffer (~64 KB): it blocks in write() and never
/// exits. This drains stdout and stderr concurrently while the child runs,
/// enforces a deadline, escalates SIGTERM → SIGKILL, and always reaps.
enum ProcessRunner {
    /// - Parameters:
    ///   - stdin: bytes written to the child's stdin (then closed); nil means
    ///     /dev/null, so a child can never block on an inherited terminal.
    ///   - environment: full environment for the child; nil inherits ours.
    ///   - timeout: wall-clock budget from launch.
    ///   - killGrace: how long SIGTERM gets before SIGKILL.
    ///   - directory: the child's working directory; nil inherits ours.
    /// - Throws: only when the executable cannot be launched. Non-zero exit
    ///   and timeouts are reported in the result.
    static func run(_ executable: URL, _ arguments: [String] = [],
                    stdin: Data? = nil,
                    environment: [String: String]? = nil,
                    timeout: TimeInterval,
                    killGrace: TimeInterval = 2,
                    directory: URL? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        let outBox = DrainBuffer()
        let errBox = DrainBuffer()
        let drains = DispatchGroup()
        drain(outPipe.fileHandleForReading, into: outBox, group: drains)
        drain(errPipe.fileHandleForReading, into: errBox, group: drains)

        if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            // A child that exits without reading stdin must not SIGPIPE us.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

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

        // EOF normally arrives with exit. A grandchild that inherited the
        // pipe can hold it open; don't let its lifetime extend ours.
        _ = drains.wait(timeout: .now() + 2)

        return ProcessResult(status: process.terminationStatus,
                             stdout: outBox.data, stderr: errBox.data,
                             timedOut: timedOut)
    }

    private static func drain(_ handle: FileHandle, into box: DrainBuffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            // Raw read(2), not FileHandle.read(upToCount:): that one waits
            // for the full count or EOF, so output written before a
            // grandchild kept the pipe open would never be appended.
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
}

/// Lock-protected accumulator for one pipe drain.
private final class DrainBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock(); buffer.append(chunk); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }; return buffer
    }
}
