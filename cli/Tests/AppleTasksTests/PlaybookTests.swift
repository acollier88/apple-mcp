import XCTest
@testable import apple_tasks

final class PlaybookTests: XCTestCase {
    func testLadderAndForbiddenCommands() {
        XCTAssertEqual(Playbooks.rung(for: "homeassistant"), .agent)
        XCTAssertEqual(Playbooks.rung(for: "logs-oversize"), .playbook("logs-oversize"))
        XCTAssertEqual(Playbooks.rung(for: "binary-drift"), .needsHuman("binary-drift"))
        XCTAssertFalse(Playbooks.allowedArgv(["/usr/bin/git", "push", "origin", "main"]))
        XCTAssertFalse(Playbooks.allowedArgv(["/usr/bin/git", "branch", "-D", "agent/x"]))
        XCTAssertTrue(Playbooks.allowedArgv([
            "/usr/bin/git", "worktree", "remove", "--force", "/tmp/wt"]))
        XCTAssertFalse(Playbooks.allowedArgv([
            "/bin/kill", "-TERM", "not-a-pid"]))
        XCTAssertFalse(Playbooks.isInfrastructure("the patch did not compile"))
        XCTAssertTrue(Playbooks.isInfrastructure("dispatcher died"))
        XCTAssertTrue(Playbooks.countsAfterReset(finishedAt: "2026-11-02T00:00:00Z", ignoreBefore: "2026-11-01T00:00:00Z"))
        XCTAssertFalse(Playbooks.countsAfterReset(finishedAt: "2026-10-01T00:00:00Z", ignoreBefore: "2026-11-01T00:00:00Z"))
    }

    func testPlanKeepsBranchesAndRefusesForeignProcesses() {
        var ctx = Playbooks.Context()
        ctx.hungPid = 44
        ctx.hungCommand = "/usr/bin/sleep 10"
        ctx.worktrees = [(path: "/tmp/agent-wt", ageDays: 9)]
        ctx.claims = [(title: "[dispatched:other] [auto] Fix it", ageDays: 30),
                      (title: "[dispatched:\(ClaimTags.host)] Fix ours", ageDays: 30)]
        ctx.retries = [(taskId: "t1", summary: "connection reset", alreadyReset: false),
                       (taskId: "t2", summary: "connection reset", alreadyReset: true),
                       (taskId: "t3", summary: "model refused", alreadyReset: false)]
        ctx.deploymentNote = "binary is behind HEAD"
        let steps = Playbooks.plan(ctx)
        XCTAssertTrue(steps.contains { $0.playbook == "dispatcher-hung" && $0.apply == .none })
        let git = steps.first { $0.playbook == "worktree-retention" }
        XCTAssertEqual(git?.apply, .argv(["/usr/bin/git", "worktree", "remove", "--force", "/tmp/agent-wt"]))
        let titles = steps.compactMap { step -> String? in
            if case .retitle(_, let new) = step.apply { return new }
            return nil
        }
        XCTAssertEqual(titles, ["Fix ours"])
        XCTAssertEqual(steps.filter { $0.playbook == "retries-exhausted" }.count, 1)
        XCTAssertTrue(steps.contains { $0.playbook == "binary-drift" })
    }

    func testLogRotateStaysInsideTheLogsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heal-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("dispatch.stderr.log")
        try Data(repeating: 1, count: 32).write(to: log)
        XCTAssertFalse(Playbooks.logIsInside("/tmp/credentials.json", root: root.path))
        let moved = try Playbooks.rotateLog(at: log.path, root: root.path)
        XCTAssertEqual(moved, log.path + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertEqual(try Data(contentsOf: log), Data())
        XCTAssertThrowsError(try Playbooks.rotateLog(at: "/tmp/credentials.json", root: root.path))
    }
}
