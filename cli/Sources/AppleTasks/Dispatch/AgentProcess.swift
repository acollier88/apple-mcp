import Darwin
import Foundation

/// Signal and identify agent processes recorded on `dispatches.pid`.
///
/// Foundation `Process` has no process-group hook (and we do not reach for
/// `posix_spawn` here), so spawned agents stay in the dispatcher's group and
/// `kill(-pid)` is not available. `terminate` instead walks the descendant
/// tree via `pgrep -P` and signals every process in it (leaf-first), so the
/// node/shell grandchildren that `agent` / `claude` spawn go down with them.
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

    /// SIGTERM the process and all its descendants, poll, then SIGKILL any
    /// survivors. Returns `terminated` | `killed` | `gone`.
    static func terminate(_ pid: Int32, graceSeconds: Double = 5) -> String {
        guard isAlive(pid) else { return "gone" }
        let tree = signalTree(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(graceSeconds)
        while tree.contains(where: isAlive), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        let survivors = tree.filter(isAlive)
        if survivors.isEmpty { return "terminated" }
        for p in survivors { kill(p, SIGKILL) }
        return "killed"
    }

    /// Send `sig` to `pid` and every descendant; returns the pids signalled
    /// (leaf-first, root last) so callers can poll them for survivors. The
    /// tree is snapshotted before signalling: once the parent dies its
    /// children are reparented to launchd and `pgrep -P` can't find them.
    @discardableResult
    static func signalTree(_ pid: Int32, _ sig: Int32) -> [Int32] {
        let tree = descendants(of: pid) + [pid]
        for p in tree { kill(p, sig) }
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
}
