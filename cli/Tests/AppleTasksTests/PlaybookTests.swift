import XCTest
@testable import apple_tasks

final class PlaybookTests: XCTestCase {
    func testLadderMatchesDetectorSignatures() {
        XCTAssertEqual(Playbooks.rung(for: "homeassistant"), .agent)
        XCTAssertEqual(Playbooks.rung(for: "disk-logs"), .playbook("disk-logs"))
        XCTAssertEqual(Playbooks.rung(for: "launch-not-loaded"), .playbook("launch-not-loaded"))
        XCTAssertEqual(Playbooks.rung(for: "dispatcher-hung"), .playbook("dispatcher-hung"))
        XCTAssertEqual(Playbooks.rung(for: "deployment-drift"), .needsHuman("deployment-drift"))
        // Retention and retries are not playbooks (GC and #77 own them).
        XCTAssertEqual(Playbooks.rung(for: "disk-worktrees"), .agent)
        XCTAssertEqual(Playbooks.rung(for: "retries-exhausted:t1"), .agent)
    }

    func testOnlyTheTwoKnownCommandsAreAllowed() {
        XCTAssertFalse(Playbooks.allowedArgv(["/usr/bin/git", "push", "origin", "main"]))
        XCTAssertFalse(Playbooks.allowedArgv(["/usr/bin/git", "worktree", "remove", "--force", "/tmp/wt"]))
        XCTAssertFalse(Playbooks.allowedArgv(["/bin/kill", "-TERM", "not-a-pid"]))
        XCTAssertFalse(Playbooks.allowedArgv(["/bin/kill", "-TERM", "1"]))
        XCTAssertFalse(Playbooks.allowedArgv(["/bin/kill", "-KILL", "4242"]))
        XCTAssertTrue(Playbooks.allowedArgv(["/bin/kill", "-TERM", "4242"]))
        XCTAssertTrue(Playbooks.allowedArgv([
            "/bin/launchctl", "bootstrap", "gui/501", "/Users/x/Library/LaunchAgents/com.apple-tasks.dispatch.plist"]))
        XCTAssertFalse(Playbooks.allowedArgv([
            "/bin/launchctl", "bootstrap", "gui/501", "/tmp/evil.plist"]))
    }

    func testHungDispatcherNeedsAgeAndALiveDispatchProcess() {
        let rows: [(ledgerId: Int, dispatcherPid: Int?, ageSeconds: TimeInterval, timeoutSeconds: TimeInterval)] = [
            (1, 4242, 3600, 3600),            // at timeout, within grace
            (2, nil, 99_999, 3600),           // no dispatcher pid on record
            (3, 5151, 3600 + 1200, 3600),     // 10 min past timeout + grace
        ]
        let hung = Playbooks.hungDispatcher(rows: rows) { pid in
            pid == 5151 ? "/Users/x/.local/bin/apple-tasks dispatch --quiet" : nil
        }
        XCTAssertEqual(hung?.pid, 5151)
        XCTAssertEqual(hung?.ledgerId, 3)
        XCTAssertNil(Playbooks.hungDispatcher(rows: rows) { _ in nil })
    }

    func testPlanReleasesOnlyOurOldClaimsAndRefusesForeignProcesses() {
        var ctx = Playbooks.Context()
        ctx.hung = .init(pid: 44, command: "/usr/bin/sleep 10", ledgerId: 9, overSeconds: 60)
        ctx.claims = [
            .init(taskId: "a", title: "[dispatched:other-mac] [auto] Fix it", ageDays: 30),
            .init(taskId: "b", title: "[dispatched:\(ClaimTags.host)] Fix ours", ageDays: 30),
            .init(taskId: "c", title: "[dispatched:\(ClaimTags.host)] Fresh", ageDays: 2),
        ]
        let steps = Playbooks.plan(ctx)
        XCTAssertTrue(steps.contains { $0.playbook == "dispatcher-hung" && $0.apply == .none })
        let released = steps.compactMap { step -> String? in
            if case .releaseClaim(let id, let title) = step.apply { return "\(id):\(title)" }
            return nil
        }
        XCTAssertEqual(released, ["b:Fix ours"])

        var real = Playbooks.Context()
        real.hung = .init(pid: 4242, command: "/Users/x/.local/bin/apple-tasks dispatch --quiet",
                          ledgerId: 9, overSeconds: 60)
        XCTAssertEqual(Playbooks.plan(real, only: "dispatcher-hung").first?.apply,
                       .argv(["/bin/kill", "-TERM", "4242"]))
        var cancel = Playbooks.Context()
        cancel.hung = .init(pid: 4243, command: "apple-tasks dispatch-cancel 9", ledgerId: 9, overSeconds: 60)
        XCTAssertEqual(Playbooks.plan(cancel).first?.apply, Playbooks.Apply.none)
    }

    func testLogRotateStaysInsideTheLogsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heal-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("dispatch.stderr.log")
        try Data(repeating: 1, count: 32).write(to: log)
        XCTAssertFalse(Playbooks.logIsInside("/tmp/credentials.json", root: root.path))
        XCTAssertFalse(Playbooks.logIsInside(log.path, root: ""))
        let moved = try Playbooks.rotateLog(at: log.path, root: root.path)
        XCTAssertEqual(moved, log.path + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertEqual(try Data(contentsOf: log), Data())
        XCTAssertThrowsError(try Playbooks.rotateLog(at: "/tmp/credentials.json", root: root.path))
    }
}
