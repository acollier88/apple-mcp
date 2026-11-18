import Darwin
import XCTest
@testable import apple_tasks

final class AgentProcessTests: XCTestCase {
    private var spawned: [Process] = []

    override func tearDown() {
        for process in spawned where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        spawned.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func spawn(_ exe: String, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        return process
    }

    func testIsAliveAndTerminateSleep() throws {
        let process = try spawn("/bin/sleep", ["600"])
        let pid = process.processIdentifier
        XCTAssertTrue(AgentProcess.isAlive(pid))

        let start = Date()
        let result = AgentProcess.terminate(pid, graceSeconds: 1)
        XCTAssertEqual(result, "terminated")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertFalse(AgentProcess.isAlive(pid))
        process.waitUntilExit()
    }

    /// A shell that spawns a grandchild: terminating the shell must also take
    /// the grandchild down (Process has no process group to lean on).
    func testTerminateKillsGrandchildren() throws {
        // sh -> sleep 600 (foreground child). Without `exec` the shell stays
        // the parent, so the tree is sh(pid) -> sleep.
        let shell = try spawn("/bin/sh", ["-c", "sleep 600; true"])
        let pid = shell.processIdentifier
        var kids: [Int32] = []
        for _ in 0..<40 where kids.isEmpty {           // give sh time to fork
            kids = AgentProcess.descendants(of: pid)
            if kids.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertEqual(kids.count, 1, "expected exactly one grandchild (sleep)")
        let sleepPid = kids[0]
        XCTAssertTrue(AgentProcess.isAlive(sleepPid))

        XCTAssertEqual(AgentProcess.terminate(pid, graceSeconds: 2), "terminated")
        shell.waitUntilExit()
        // sleep was reparented to launchd when sh died; it must be gone too.
        for _ in 0..<20 where AgentProcess.isAlive(sleepPid) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(AgentProcess.isAlive(sleepPid), "grandchild survived the tree kill")
    }

    func testIsAliveRejectsBogusPid() {
        XCTAssertFalse(AgentProcess.isAlive(999999))
    }

    func testLooksLikeOursRequiresAMarker() throws {
        let process = try spawn("/bin/sleep", ["600"])
        let pid = process.processIdentifier
        XCTAssertTrue(AgentProcess.isAlive(pid))
        XCTAssertFalse(AgentProcess.looksLikeOurs(pid, ledgerId: 424242,
                                                 taskId: "TASK-ABC", agent: "cursor"))

        let marked = try spawn("/bin/sh", ["-c", "sleep 600", "TASK-ABC"])
        let markedPid = marked.processIdentifier
        XCTAssertTrue(AgentProcess.looksLikeOurs(markedPid, ledgerId: 424242,
                                                 taskId: "TASK-ABC", agent: "cursor"))
    }

    func testLooksLikeDispatcherMatchesDispatchArgvOnly() throws {
        let cancel = try spawn("/bin/sh", ["-c", "sleep 30", "apple-tasks", "dispatch-cancel"])
        XCTAssertFalse(AgentProcess.looksLikeDispatcher(cancel.processIdentifier))
        let live = try spawn("/bin/sh", ["-c", "sleep 30", "apple-tasks", "dispatch"])
        XCTAssertTrue(AgentProcess.looksLikeDispatcher(live.processIdentifier))
        XCTAssertFalse(AgentProcess.looksLikeDispatcher(ProcessInfo.processInfo.processIdentifier))
    }

    func testOrphanedDispatchSummaryDistinguishesDispatcher() {
        XCTAssertEqual(
            Dispatch.orphanedDispatchSummary(dispatcherAlive: true),
            "agent exited but dispatcher never recorded the result")
        XCTAssertEqual(
            Dispatch.orphanedDispatchSummary(dispatcherAlive: false),
            "dispatcher process is gone")
    }

    /// Acceptance for #40: the direct child exits, a grandchild keeps stdout
    /// open. The run must finish in seconds — the drain grace, not `sleep 30`.
    func testGrandchildHoldingStdoutCompletesWithinGrace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("grandchild.pid").path
        let logPath = dir.appendingPathComponent("run.log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try XCTUnwrap(FileHandle(forWritingAtPath: logPath))
        defer { try? log.close() }
        let filter = CursorNDJSONFilter(log: log)
        let ndjson = #"{"type":"system","subtype":"init","model":"composer-1","session_id":"sess-40"}"#
        let script = "sleep 30 & echo $! > '\(pidFile)'; echo '\(ndjson)'"

        let start = Date()
        let result = try AgentProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            captureStdout: true,
            onStdout: { filter.ingest($0) })
        filter.flush()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 6, "grandchild holding stdout extended the run to \(elapsed)s")
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(filter.resolvedModel, "composer-1")
        XCTAssertEqual(filter.sessionId, "sess-40")

        let raw = try String(contentsOfFile: pidFile, encoding: .utf8)
        let grandchild = try XCTUnwrap(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if AgentProcess.isAlive(grandchild) { kill(grandchild, SIGKILL) } }
        for _ in 0..<40 where AgentProcess.isAlive(grandchild) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(AgentProcess.isAlive(grandchild), "grandchild survived the process-group signal")
    }

    /// A grandchild that has left the process group (`setsid`) still holds
    /// stdout. Group kill cannot see it; the post-exit drain must stop anyway.
    func testSessionLeaderHoldingStdoutStopsAtDrainGrace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("grandchild.pid").path
        let scriptURL = dir.appendingPathComponent("hold.rb")
        try """
        child = fork do
          Process.setsid
          sleep 30
        end
        File.write(ARGV[0], child.to_s)
        STDOUT.puts "started"
        STDOUT.flush
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let box = OutputBox()
        let start = Date()
        let result = try AgentProcess.run(
            executable: "/usr/bin/ruby",
            arguments: [scriptURL.path, pidFile],
            captureStdout: true,
            onStdout: { box.append($0) })
        let elapsed = Date().timeIntervalSince(start)
        let grandchild = try readPid(pidFile)
        defer { if AgentProcess.isAlive(grandchild) { kill(grandchild, SIGKILL) } }

        XCTAssertLessThan(elapsed, 6, "setsid grandchild holding stdout extended the run to \(elapsed)s")
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(box.string.contains("started"), box.string)
        XCTAssertTrue(AgentProcess.isAlive(grandchild),
                      "drain grace should return while the setsid grandchild still holds stdout")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-hang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readPid(_ path: String) throws -> Int32 {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return try XCTUnwrap(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
