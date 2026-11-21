import EventKit
import XCTest
@testable import apple_tasks

/// In-memory Reminders for whole-pass tests (#67). EventKit objects are made
/// from an EKEventStore that is never asked for access; nothing is saved to
/// the real store. A fake agent can act on a task by appending
/// `complete <id>` to the ops file; ops are applied before every read.
final class FakeStore: Store {
    private(set) var calendarsByTitle: [String: EKCalendar] = [:]
    private(set) var items: [EKReminder] = []
    let opsFile: URL

    init(lists: [String], opsFile: URL) {
        self.opsFile = opsFile
        super.init()
        for title in lists {
            let calendar = EKCalendar(for: .reminder, eventStore: ek)
            calendar.title = title
            calendarsByTitle[title.lowercased()] = calendar
        }
    }

    @discardableResult
    func add(_ title: String, list: String = "Code Tasks", notes: String? = nil) -> EKReminder {
        let reminder = EKReminder(eventStore: ek)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendarsByTitle[list.lowercased()]
        items.append(reminder)
        return reminder
    }

    func id(_ reminder: EKReminder) -> String {
        reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
    }

    private func applyOps() {
        guard let text = try? String(contentsOf: opsFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: opsFile)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "complete" else { continue }
            items.first { id($0) == parts[1] }?.isCompleted = true
        }
    }

    override func requestAccess() async throws {}

    override func calendar(named name: String) throws -> EKCalendar {
        guard let calendar = calendarsByTitle[name.lowercased()] else { throw AppleTasksError.listNotFound(name) }
        return calendar
    }

    override func reminders(in calendars: [EKCalendar]?) async -> [EKReminder] {
        applyOps()
        guard let calendars else { return items }
        let titles = Set(calendars.map { $0.title.lowercased() })
        return items.filter { titles.contains($0.calendar?.title.lowercased() ?? "") }
    }

    override func reminder(id: String) async throws -> EKReminder {
        applyOps()
        guard let match = items.first(where: { self.id($0) == id }) else { throw AppleTasksError.taskNotFound(id) }
        return match
    }

    override func save(_ reminder: EKReminder) throws {
        if !items.contains(where: { $0 === reminder }) { items.append(reminder) }
    }
}

/// A whole `dispatch` pass — plan, claim, execute, write-back, reap, GC —
/// against a temp config dir, temp ledger, `FakeStore`, and a scripted agent
/// that misbehaves on purpose (#67).
final class DispatchE2ETests: XCTestCase {
    var root: URL!
    var store: FakeStore!
    var savedEnv: [String: String?] = [:]
    var savedShared: AuditDB!

    static let agentScript = #"""
    #!/bin/sh
    # fake agent: $1 = mode, $2 = prompt
    mode=$1
    id=$(printf '%s\n' "$2" | sed -n 's/^Task id: //p' | head -n 1)
    case "$mode" in
      ok) echo "did the work, forgot to complete"; exit 0 ;;
      complete) echo "complete $id" >> "$FAKE_OPS"; echo done; exit 0 ;;
      fail) echo "boom" >&2; exit 1 ;;
      hang) sleep 120 ;;
      ignoreterm) trap '' TERM; while :; do sleep 1; done ;;
      grandchild) ( sleep 120 ) & echo "left a grandchild holding stdout"; exit 0 ;;
      bigout) head -c 1048576 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
    esac
    """#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        for dir in [config, support] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for (key, value) in ["APPLE_TASKS_CONFIG_DIR": config.path, "APPLE_TASKS_SUPPORT_DIR": support.path,
                             "APPLE_TASKS_CALLER": nil] as [String: String?] {
            savedEnv[key] = ProcessInfo.processInfo.environment[key]
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        savedShared = AuditDB.shared
        AuditDB.shared = AuditDB(url: config.appendingPathComponent("apple-tasks.db"))
        LaneReadiness.assumeSettledAndOnline = true
        let script = root.appendingPathComponent("fake-agent.sh")
        try Self.agentScript.write(to: script, atomically: true, encoding: .utf8)
        store = FakeStore(lists: ["Code Tasks"], opsFile: root.appendingPathComponent("ops"))
        let fake = store!
        Dispatch.makeStore = { fake }
    }

    override func tearDownWithError() throws {
        Dispatch.makeStore = { Store() }
        LaneReadiness.assumeSettledAndOnline = false
        AuditDB.shared = savedShared
        for (key, value) in savedEnv {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// One lane `fake` running the script in `mode`.
    func configure(mode: String, timeoutSeconds: Int = 3, extra: [String: Any] = [:]) throws {
        let agents: [String: Any] = [
            "fake": [
                "command": ["/bin/sh", root.appendingPathComponent("fake-agent.sh").path, mode, "{prompt}"],
                "timeoutSeconds": timeoutSeconds,
                "env": ["FAKE_OPS": store.opsFile.path],
            ] as [String: Any],
        ]
        var json: [String: Any] = [
            "agents": agents, "requireAutoTag": true, "notifyOn": "none", "maxConcurrent": 2,
        ]
        for (key, value) in extra { json[key] = value }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: AgentsConfig.url)
    }

    func pass() async throws {
        let command = try Dispatch.parse(["--quiet"])
        try await command.run()
    }

    func rows() -> [AuditDB.DispatchRow] { AuditDB.shared.dispatchRows(status: nil, limit: 20) }

    func tags(_ reminder: EKReminder) -> [String] { Tags.parse(reminder.title ?? "").tags }

    func testCompletedRunIsVerified() async throws {
        try configure(mode: "complete")
        let task = store.add("[auto][fake] Write the report")
        try await pass()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.status, "succeeded")
        XCTAssertEqual(row.verification, "completed")
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(AuditDB.shared.dispatchCount(since: Limits.dayStart()), 1)
    }

    func testExitZeroWithoutCompletingIsOpenClaimedAndNotRerun() async throws {
        try configure(mode: "ok")
        let task = store.add("[auto][fake] Forgetful")
        try await pass()
        XCTAssertEqual(rows().first?.status, "succeeded")
        XCTAssertEqual(rows().first?.verification, "open-claimed")
        XCTAssertFalse(task.isCompleted)
        try await pass()
        XCTAssertEqual(rows().count, 1, "the claim tag keeps a forgetful success from running again")
    }

    func testFailureTagsTheTaskFailed() async throws {
        try configure(mode: "fail")
        let task = store.add("[auto][fake] Breaks")
        try await pass()
        XCTAssertEqual(rows().first?.status, "failed")
        XCTAssertTrue(tags(task).contains(ClaimTags.failed), "tags: \(tags(task))")
        XCTAssertFalse(tags(task).contains(ClaimTags.dispatched))
    }

    func testHangIsKilledAtTheLaneTimeout() async throws {
        try configure(mode: "hang", timeoutSeconds: 2)
        store.add("[auto][fake] Hangs")
        let start = Date()
        try await pass()
        XCTAssertEqual(rows().first?.status, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testAgentIgnoringSIGTERMIsKilled() async throws {
        try configure(mode: "ignoreterm", timeoutSeconds: 2)
        store.add("[auto][fake] Stubborn")
        let start = Date()
        try await pass()
        XCTAssertEqual(rows().first?.status, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    /// #40: the agent exits but a grandchild keeps stdout open. The pass used
    /// to wait on that pipe forever, blocking dispatch for weeks.
    func testGrandchildHoldingStdoutDoesNotHangThePass() async throws {
        try configure(mode: "grandchild", timeoutSeconds: 60)
        store.add("[auto][fake] Leaves a child")
        let start = Date()
        try await pass()
        XCTAssertEqual(rows().first?.status, "succeeded")
        XCTAssertLessThan(Date().timeIntervalSince(start), 45, "the post-exit drain must be bounded")
    }

    func testLargeOutputIsLoggedAndTheRunSucceeds() async throws {
        try configure(mode: "bigout")
        store.add("[auto][fake] Chatty")
        try await pass()
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.status, "succeeded")
        let size = (try? FileManager.default.attributesOfItem(atPath: row.runLogPath ?? ""))?[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1_000_000)
    }

    func testUntaggedAndForeignClaimedTasksAreLeftAlone() async throws {
        try configure(mode: "complete")
        let plain = store.add("[fake] No auto tag")
        let foreign = store.add("[auto][fake][dispatched:someothermac] Running elsewhere")
        try await pass()
        XCTAssertTrue(rows().isEmpty)
        XCTAssertFalse(plain.isCompleted)
        XCTAssertFalse(foreign.isCompleted)
    }

    func testDailyLimitHoldsTheSecondTask() async throws {
        try configure(mode: "complete", extra: ["limits": ["maxPerDay": 1]])
        store.add("[auto][fake] First")
        let second = store.add("[auto][fake] Second")
        try await pass()
        XCTAssertEqual(rows().count, 1)
        XCTAssertFalse(second.isCompleted)
        XCTAssertFalse(tags(second).contains(ClaimTags.dispatched))
        // Daily caps are reported by `limits`, not as a stuck queue (#57).
        XCTAssertTrue(Diagnostics.readWaiting().isEmpty)
        XCTAssertEqual(Limits.status(limits: DispatchLimits(maxPerDay: 1), lanes: ["fake"]).reached, ["limit:total"])
    }

    func testPauseHoldsEveryClaim() async throws {
        try configure(mode: "complete")
        let task = store.add("[auto][fake] After stop")
        _ = try Dispatch.applyPause(db: .shared, until: Date().addingTimeInterval(3600), reason: "stopped")
        try await pass()
        XCTAssertTrue(rows().isEmpty)
        XCTAssertFalse(task.isCompleted)
    }
}
