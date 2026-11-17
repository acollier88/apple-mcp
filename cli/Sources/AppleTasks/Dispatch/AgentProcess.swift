import Darwin
import Foundation

/// Signal and identify agent processes recorded on `dispatches.pid`.
///
/// `run` spawns each agent with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`,
/// so the agent is its own process-group leader. `terminate` signals that
/// group — a grandchild reparented to launchd is still a member — and also
/// walks `pgrep -P` for descendants that left the group while the parent
/// was alive. Foundation `Process` has no process-group hook; `run` does
/// not use it. `commandLine` / `descendants` still shell out for inspection.
enum AgentProcess {
    /// `kill(pid, 0)`: exists, or exists-but-not-ours (`EPERM`).
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// `ps -o command=` for the pid, or nil if ps fails / the pid is gone.
    static func commandLine(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (line?.isEmpty == false) ? line : nil
    }

    /// Conservative PID-reuse guard: alive AND the command line mentions
    /// the task id, this run's log path, or the configured agent basename.
    /// A missing command line is "not ours".
    static func looksLikeOurs(_ pid: Int32, ledgerId: Int64, taskId: String, agent: String) -> Bool {
        guard isAlive(pid), let cmd = commandLine(pid) else { return false }
        if !taskId.isEmpty, cmd.contains(taskId) { return true }
        if cmd.contains("runs/\(ledgerId).log") { return true }
        if let basename = agentBinaryName(agent), !basename.isEmpty, cmd.contains(basename) {
            return true
        }
        return false
    }

    /// True when `pid` is alive, is not us, and its command line is an
    /// `apple-tasks dispatch` pass (not `dispatch-cancel` / `dispatch-pause`).
    /// Used to tell a dispatcher that is stuck after the agent exited from
    /// one that has already died. A reused pid that is this process does not
    /// count: the dispatcher that owned the row is gone.
    static func looksLikeDispatcher(_ pid: Int32) -> Bool {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        guard isAlive(pid), let cmd = commandLine(pid) else { return false }
        let parts = cmd.split(whereSeparator: \.isWhitespace).map { String($0) }
        let isBinary = parts.contains { part in
            let base = URL(fileURLWithPath: part).lastPathComponent
            return base == "apple-tasks"
        }
        return isBinary && parts.contains("dispatch")
    }

    /// `pid` is a process-group leader. False when the pid is already gone
    /// (`getpgid` fails); callers that spawned the group still have the id.
    static func isGroupLeader(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return getpgid(pid) == pid
    }

    /// Anyone left in the group whose id is `pgid` (the leader's pid). Works
    /// after the leader has exited, which is when reparented grandchildren
    /// are invisible to `pgrep -P`.
    static func groupHasMembers(_ pgid: Int32) -> Bool {
        guard pgid > 1 else { return false }
        if kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Signal a process group we created (`POSIX_SPAWN_SETPGROUP`, pgid = pid).
    /// `kill(-1)` would hit every process we can signal, so pgid must be > 1.
    static func signalOwnGroup(_ pgid: Int32, _ sig: Int32) {
        guard pgid > 1 else { return }
        kill(-pgid, sig)
    }

    /// SIGTERM the process, its descendant tree, and its process group when
    /// it is the leader; poll; SIGKILL survivors. Returns `terminated` |
    /// `killed` | `gone`.
    static func terminate(_ pid: Int32, graceSeconds: Double = 5) -> String {
        guard isAlive(pid) else { return "gone" }
        let leader = isGroupLeader(pid)
        let tree = signalTree(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(graceSeconds)
        func lingering() -> Bool {
            tree.contains(where: isAlive) || (leader && groupHasMembers(pid))
        }
        while lingering(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !lingering() { return "terminated" }
        for p in tree where isAlive(p) { kill(p, SIGKILL) }
        if leader { signalOwnGroup(pid, SIGKILL) }
        return "killed"
    }

    /// Send `sig` to `pid` and every descendant; returns the pids signalled
    /// (leaf-first, root last) so callers can poll them for survivors. The
    /// tree is snapshotted before signalling: once the parent dies its
    /// children are reparented to launchd and `pgrep -P` can't find them.
    /// When `pid` is a group leader the group is signalled too, which still
    /// reaches those reparented members.
    @discardableResult
    static func signalTree(_ pid: Int32, _ sig: Int32) -> [Int32] {
        let tree = descendants(of: pid) + [pid]
        for p in tree { kill(p, sig) }
        if isGroupLeader(pid) { signalOwnGroup(pid, sig) }
        return tree
    }

    /// Transitive children of `pid` via `pgrep -P`, deepest first, so
    /// signalling in order reaches leaves before their parents.
    static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        for child in children(of: pid) {
            result.append(contentsOf: descendants(of: child))
            result.append(child)
        }
        return result
    }

    private static func children(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // pgrep exits 1 when there are no matches; that's an empty list, not an error.
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `AgentsConfig.agents[tag].command[0]` basename, if config loads.
    private static func agentBinaryName(_ agent: String) -> String? {
        guard let config = try? AgentsConfig.load() else { return nil }
        let first = config.agents[agent]?.command?.first
            ?? config.agents[agent]?.commandTemplate(tag: agent)?.first
        guard let first, !first.isEmpty else { return nil }
        return URL(fileURLWithPath: first).lastPathComponent
    }

    struct AgentRunResult: Sendable {
        let status: Int32
        let timedOut: Bool
    }

    /// How long to keep reading stdout after the direct child has exited.
    /// A grandchild that inherited the pipe's write end would otherwise block
    /// the pass forever. Same budget `ProcessRunner` uses for its post-exit
    /// drain; unlike that helper we then close the read end so this
    /// long-lived process actually stops reading.
    static let stdoutDrainGrace: TimeInterval = 2

    /// Spawn `executable` in its own process group and wait for it.
    ///
    /// Stdout is either duplicated from `standardOutput` or, when
    /// `captureStdout` is set, streamed to `onStdout` while the child runs
    /// (so a chatty agent cannot fill the pipe and stall) and for at most
    /// `drainGrace` after it exits. The group is signalled on timeout and
    /// again after exit, so grandchildren die even if they were reparented.
    /// `onSpawn` runs after a successful spawn and before the wait, which is
    /// when the ledger records the pid.
    static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: String? = nil,
        stdin: Data? = nil,
        standardOutput: FileHandle? = nil,
        standardError: FileHandle? = nil,
        captureStdout: Bool = false,
        timeout: TimeInterval? = nil,
        drainGrace: TimeInterval = stdoutDrainGrace,
        onSpawn: ((Int32) -> Void)? = nil,
        onStdout: ((Data) -> Void)? = nil
    ) throws -> AgentRunResult {
        let spawned = try spawn(
            executable: executable,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment,
            directory: directory,
            stdin: stdin,
            standardOutput: captureStdout ? nil : standardOutput,
            standardError: standardError,
            captureStdout: captureStdout)
        let drain: StdoutDrain?
        if let fd = spawned.stdoutRead {
            let box = StdoutDrain(fd: fd)
            box.start { chunk in onStdout?(chunk) }
            drain = box
        } else {
            drain = nil
        }
        if let writeFD = spawned.stdinWrite, let stdin {
            _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                _ = stdin.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(writeFD, base.advanced(by: off), raw.count - off)
                        if n > 0 {
                            off += n
                        } else if n < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    return off
                }
                Darwin.close(writeFD)
            }
        }

        noteSpawned(spawned.pid)
        defer { noteExited(spawned.pid) }
        onSpawn?(spawned.pid)

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while !spawned.hasExited() {
                if Date() >= deadline {
                    timedOut = true
                    _ = terminate(spawned.pid)
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let status = spawned.exitCode()
        // Child is gone. A grandchild may still hold the stdout write end
        // and, once reparented, is invisible to pgrep. The group signal
        // reaches members that stayed; the drain grace covers one that left.
        signalOwnGroup(spawned.pid, SIGTERM)
        drain?.finish(grace: drainGrace)
        if groupHasMembers(spawned.pid) {
            signalOwnGroup(spawned.pid, SIGKILL)
        }
        return AgentRunResult(status: status, timedOut: timedOut)
    }

    /// Pids `run` has spawned and not yet reaped. The pass watchdog SIGKILLs
    /// these so a stuck pass does not leave agents behind when it exits.
    private static let trackedLock = NSLock()
    private static var trackedPids: [Int32] = []

    static func killTracked() {
        trackedLock.lock()
        let pids = trackedPids
        trackedLock.unlock()
        for pid in pids where pid > 1 {
            kill(pid, SIGKILL)
            signalOwnGroup(pid, SIGKILL)
        }
    }

    private static func noteSpawned(_ pid: Int32) {
        trackedLock.lock()
        trackedPids.append(pid)
        trackedLock.unlock()
    }

    private static func noteExited(_ pid: Int32) {
        trackedLock.lock()
        trackedPids.removeAll { $0 == pid }
        trackedLock.unlock()
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String?,
        stdin: Data?,
        standardOutput: FileHandle?,
        standardError: FileHandle?,
        captureStdout: Bool
    ) throws -> SpawnedAgent {
        var attr: posix_spawnattr_t?
        let attrRC = posix_spawnattr_init(&attr)
        guard attrRC == 0 else { throw AgentSpawnError(code: attrRC) }
        defer { posix_spawnattr_destroy(&attr) }
        let flagsRC = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        guard flagsRC == 0 else { throw AgentSpawnError(code: flagsRC) }
        let pgroupRC = posix_spawnattr_setpgroup(&attr, 0)
        guard pgroupRC == 0 else { throw AgentSpawnError(code: pgroupRC) }

        var actions: posix_spawn_file_actions_t?
        let actionsRC = posix_spawn_file_actions_init(&actions)
        guard actionsRC == 0 else { throw AgentSpawnError(code: actionsRC) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var closeAfter: [Int32] = []
        defer { for fd in closeAfter { Darwin.close(fd) } }

        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds = [Int32](repeating: -1, count: 2)
            let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.pipe(base)
            }
            guard rc == 0, fds[0] >= 0, fds[1] >= 0 else { throw AgentSpawnError(code: errno) }
            closeAfter.append(fds[0])
            closeAfter.append(fds[1])
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            return (fds[0], fds[1])
        }

        var stdoutRead: Int32?
        if captureStdout {
            let ends = try makePipe()
            stdoutRead = ends.read
            try Self.check(posix_spawn_file_actions_adddup2(&actions, ends.write, STDOUT_FILENO))
            try Self.check(posix_spawn_file_actions_addclose(&actions, ends.read))
            try Self.check(posix_spawn_file_actions_addclose(&actions, ends.write))
        } else if let standardOutput {
            try Self.check(posix_spawn_file_actions_adddup2(
                &actions, standardOutput.fileDescriptor, STDOUT_FILENO))
        }

        if let standardError {
            try Self.check(posix_spawn_file_actions_adddup2(
                &actions, standardError.fileDescriptor, STDERR_FILENO))
        }

        var stdinWrite: Int32?
        if stdin != nil {
            let ends = try makePipe()
            stdinWrite = ends.write
            try Self.check(posix_spawn_file_actions_adddup2(&actions, ends.read, STDIN_FILENO))
            try Self.check(posix_spawn_file_actions_addclose(&actions, ends.read))
            try Self.check(posix_spawn_file_actions_addclose(&actions, ends.write))
        }

        if let directory {
            let chdirRC = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
            guard chdirRC == 0 else { throw AgentSpawnError(code: chdirRC) }
        }

        // Foundation.Process puts the executable path in argv[0] and
        // `arguments` after it. `/usr/bin/env` needs that shape.
        let argv = [executable] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnRC: Int32 = executable.withCString { path in
            withCStringArray(argv) { argvPtr in
                withCStringArray(env) { envPtr in
                    posix_spawn(&pid, path, &actions, &attr, argvPtr, envPtr)
                }
            }
        }
        guard spawnRC == 0, pid > 1 else { throw AgentSpawnError(code: spawnRC == 0 ? ECHILD : spawnRC) }

        if let stdoutRead { closeAfter.removeAll { $0 == stdoutRead } }
        if let stdinWrite { closeAfter.removeAll { $0 == stdinWrite } }
        return SpawnedAgent(pid: pid, stdoutRead: stdoutRead, stdinWrite: stdinWrite)
    }

    private static func check(_ rc: Int32) throws {
        guard rc == 0 else { throw AgentSpawnError(code: rc) }
    }
}

struct AgentSpawnError: LocalizedError {
    let code: Int32
    var errorDescription: String? {
        "posix_spawn failed: \(String(cString: strerror(code)))"
    }
}

/// One `posix_spawn`'d agent. `waitpid` state stays on the caller thread.
private final class SpawnedAgent {
    let pid: Int32
    let stdoutRead: Int32?
    let stdinWrite: Int32?
    private var collected: Int32?

    init(pid: Int32, stdoutRead: Int32?, stdinWrite: Int32?) {
        self.pid = pid
        self.stdoutRead = stdoutRead
        self.stdinWrite = stdinWrite
    }

    func hasExited() -> Bool {
        if collected != nil { return true }
        var status: Int32 = 0
        let rc = waitpid(pid, &status, WNOHANG)
        if rc == pid {
            collected = status
            return true
        }
        return false
    }

    /// Foundation `Process.terminationStatus`: exit code, or the signal number.
    func exitCode() -> Int32 {
        let raw: Int32
        if let collected {
            raw = collected
        } else {
            var status: Int32 = 0
            while true {
                let rc = waitpid(pid, &status, 0)
                if rc == pid { break }
                if errno != EINTR { return -1 }
            }
            collected = status
            raw = status
        }
        if raw & 0x7f == 0 { return (raw >> 8) & 0xff }
        return raw & 0x7f
    }
}

/// Drains one pipe with `read(2)` (not `FileHandle.read(upToCount:)`, which
/// waits for a full count or EOF). After the grace, `finish` closes the fd
/// so a grandchild holding the write end cannot keep this thread — or the
/// dispatcher — blocked.
private final class StdoutDrain: @unchecked Sendable {
    private let fd: Int32
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stopped = false

    init(fd: Int32) { self.fd = fd }

    func start(_ onChunk: @escaping (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [fd] in
            defer { self.group.leave() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !self.isStopped {
                let n = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.read(fd, base, raw.count)
                }
                if n > 0 {
                    onChunk(Data(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func finish(grace: TimeInterval) {
        if group.wait(timeout: .now() + grace) == .timedOut {
            lock.lock()
            stopped = true
            lock.unlock()
            Darwin.close(fd)
            _ = group.wait(timeout: .now() + 1)
        } else {
            Darwin.close(fd)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private func withCStringArray(
    _ values: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32
) -> Int32 {
    var copies: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    copies.append(nil)
    defer { for pointer in copies { free(pointer) } }
    return copies.withUnsafeMutableBufferPointer { buf in
        guard let base = buf.baseAddress else { return -1 }
        return body(UnsafePointer(base))
    }
}
