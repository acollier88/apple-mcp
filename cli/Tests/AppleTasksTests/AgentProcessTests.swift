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
}
