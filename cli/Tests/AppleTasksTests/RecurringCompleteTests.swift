import XCTest
@testable import apple_tasks

final class RecurringCompleteTests: XCTestCase {
    func testHumanCallerAlwaysProceeds() {
        XCTAssertEqual(
            AgentRecurringComplete.decision(caller: "Terminal (pid 1)", hasRecurrence: true, alreadyRolled: true),
            .proceed)
    }

    func testAgentSecondRollIsIgnored() {
        XCTAssertEqual(
            AgentRecurringComplete.decision(caller: "agent:cursor", hasRecurrence: true, alreadyRolled: true),
            .ignore)
    }

    func testAgentFirstRollProceeds() {
        XCTAssertEqual(
            AgentRecurringComplete.decision(caller: "agent:cursor", hasRecurrence: true, alreadyRolled: false),
            .proceed)
    }

    func testAgentOneShotProceeds() {
        XCTAssertEqual(
            AgentRecurringComplete.decision(caller: "agent:cursor", hasRecurrence: false, alreadyRolled: true),
            .proceed)
    }

    func testOccurrenceDueRoundTripAndRollMarker() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("test.db"))
        let claim = db.claimDispatch(taskId: "daily", agent: "cursor", command: "x", cwd: nil)
        guard case .claimed(let id) = claim else {
            return XCTFail("expected claimed, got \(claim)")
        }
        XCTAssertTrue(db.setOccurrenceDue(id: id, due: "2026-11-16"))
        XCTAssertEqual(db.occurrenceDue(id: id), "2026-11-16")
        XCTAssertNil(db.getState(AgentRecurringComplete.rolledKey(Int(id))))
        XCTAssertTrue(db.setState(AgentRecurringComplete.rolledKey(Int(id)), "2026-11-16"))
        XCTAssertNotNil(db.getState(AgentRecurringComplete.rolledKey(Int(id))))
        XCTAssertEqual(
            AgentRecurringComplete.decision(caller: "agent:cursor", hasRecurrence: true, alreadyRolled: true),
            .ignore)
    }
}
