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
    /// - Throws: only when the executable cannot be launched. Non-zero exit
    ///   and timeouts are reported in the result.
    static func run(_ executable: URL, _ arguments: [String] = [],
                    stdin: Data? = nil,
                    environment: [String: String]? = nil,
                    timeout: TimeInterval,
                    killGrace: TimeInterval = 2) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
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

/// Copy a pipe into the caller until EOF, without letting a grandchild that
/// inherited the write end hold the parent past `finish`'s timeout.
///
/// Reads poll instead of blocking in `read(2)`. After the child has exited,
/// `finish` waits for EOF; on timeout it asks the readers to stop and waits
/// for them to leave before the caller closes the run log.
enum PipeDrain {
    static let postExitTimeout: TimeInterval = 2

    static func copy(_ handle: FileHandle, stop: PipeStop, group: DispatchGroup,
                     onChunk: @escaping (Data) -> Void) {
        let fd = handle.fileDescriptor
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !stop.stopped {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let rc = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 200) }
                if stop.stopped { break }
                if rc == 0 { continue }
                if rc < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let ready = pfd.revents
                if ready & Int16(POLLIN) != 0 {
                    let n = buffer.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.read(fd, base, raw.count)
                    }
                    if n > 0 {
                        onChunk(Data(buffer[0..<n]))
                        continue
                    }
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                if ready & Int16(POLLHUP) != 0 || ready & Int16(POLLERR) != 0 || ready & Int16(POLLNVAL) != 0 {
                    break
                }
            }
        }
    }

    /// True when every reader saw EOF before `timeout`. Otherwise the readers
    /// are asked to stop and this returns once they have left.
    @discardableResult
    static func finish(_ group: DispatchGroup, stop: PipeStop, timeout: TimeInterval) -> Bool {
        if group.wait(timeout: .now() + timeout) == .success {
            return true
        }
        stop.stop()
        _ = group.wait(timeout: .now() + 1)
        return false
    }
}

/// Shared flag for `PipeDrain` readers. Set after the child has exited and
/// the post-exit wait has elapsed.
final class PipeStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func stop() {
        lock.lock()
        flag = true
        lock.unlock()
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
