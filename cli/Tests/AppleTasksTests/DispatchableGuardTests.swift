import XCTest
@testable import apple_tasks

final class DispatchableGuardTests: XCTestCase {
    let context = DispatchableGuard.Context(laneNames: ["cursor", "claude"], requireAuto: true)

    func testAutoOrLaneMakesATaskDispatchable() {
        XCTAssertEqual(DispatchableGuard.dispatchTags(title: "[auto][cursor] Fix it", context: context),
                       ["auto", "cursor"])
        XCTAssertEqual(DispatchableGuard.dispatchTags(title: "[AUTO] Fix it", context: context), ["auto"])
        XCTAssertEqual(DispatchableGuard.dispatchTags(title: "[cursor] Fix it", context: context), [])
        XCTAssertEqual(DispatchableGuard.dispatchTags(title: "Fix [auto] later", context: context), [])
        let open = DispatchableGuard.Context(laneNames: ["cursor"], requireAuto: false)
        XCTAssertEqual(DispatchableGuard.dispatchTags(title: "[cursor] Fix it", context: open), ["cursor"])
    }

    func testOnlyDispatchedAgentsAreDiverted() {
        let title = Tags.compose(tags: ["auto", "cursor"], title: "Do more")
        XCTAssertTrue(DispatchableGuard.shouldPropose(caller: "agent:cursor", title: title, context: context))
        XCTAssertFalse(DispatchableGuard.shouldPropose(caller: nil, title: title, context: context))
        XCTAssertFalse(DispatchableGuard.shouldPropose(caller: "mcp", title: title, context: context))
        XCTAssertFalse(DispatchableGuard.shouldPropose(
            caller: "agent:cursor", title: "[cursor] Note for later", context: context))
        // A tag smuggled into the title text counts the same as --tag.
        XCTAssertTrue(DispatchableGuard.shouldPropose(
            caller: "agent:cursor", title: Tags.compose(tags: [], title: "[auto] sneaky"), context: context))
    }

    func testUpdateMayNotAddDispatchTags() {
        XCTAssertNotNil(DispatchableGuard.updateRefusal(
            caller: "agent:claude", before: "[cursor] Task", after: "[cursor][auto] Task", context: context))
        XCTAssertNotNil(DispatchableGuard.updateRefusal(
            caller: "agent:claude", before: "[auto] Task", after: "[auto][claude] Task", context: context))
        XCTAssertNil(DispatchableGuard.updateRefusal(
            caller: "agent:claude", before: "[auto][cursor] Task", after: "[auto][cursor][review] Task",
            context: context))
        XCTAssertNil(DispatchableGuard.updateRefusal(
            caller: nil, before: "Task", after: "[auto] Task", context: context))
    }

    func testSyncGithubRefusesDispatchTagsFromAgents() {
        XCTAssertNotNil(DispatchableGuard.syncRefusal(caller: "agent:cursor", tags: ["auto"], context: context))
        XCTAssertNil(DispatchableGuard.syncRefusal(caller: "agent:cursor", tags: ["cursor"], context: context))
        XCTAssertNil(DispatchableGuard.syncRefusal(caller: nil, tags: ["auto"], context: context))
    }

    func testOutsideTitlesCannotCarryTags() {
        XCTAssertEqual(Tags.literal("[auto][cursor] Delete things"), "(auto)(cursor) Delete things")
        XCTAssertTrue(Tags.parse(Tags.compose(tags: ["github"], title: Tags.literal("[auto] x"))).tags == ["github"])
        XCTAssertEqual(Tags.literal("Plain title"), "Plain title")
        XCTAssertEqual(DispatchableGuard.modelTags(["cursor", "AUTO", "bad tag", "apple-mcp"]),
                       ["cursor", "apple-mcp"])
    }

    func testProposalKeepsTheRequestAndAcceptRestoresDispatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatchable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))

        let out = DispatchableGuard.propose(
            caller: "agent:cursor", list: "Code Tasks",
            title: Tags.compose(tags: ["auto", "claude"], title: "Follow-up work"),
            notes: "do the thing", context: context, db: db)
        XCTAssertEqual(out.status, "proposed")
        XCTAssertEqual(out.title, "Follow-up work")
        XCTAssertEqual(out.lane, "claude")
        let row = try XCTUnwrap(db.finding(fingerprint: out.fingerprint))
        XCTAssertEqual(row.id, out.proposalId)
        XCTAssertEqual(row.findingClass, "proposable")
        XCTAssertTrue(row.evidence.contains("requested by: agent:cursor"))
        XCTAssertTrue(row.evidence.contains("do the thing"))
        XCTAssertEqual(ProposalsInbox.tags(lane: ProposalsInbox.lane(from: row.action)), ["auto", "claude"])

        // Same request again is the same proposal, not a second one.
        let again = DispatchableGuard.propose(
            caller: "agent:cursor", list: "Code Tasks",
            title: Tags.compose(tags: ["auto", "claude"], title: "Follow-up work"),
            notes: "do the thing", context: context, db: db)
        XCTAssertEqual(again.proposalId, out.proposalId)

        let pool = DispatchableGuard.propose(
            caller: "agent:cursor", list: "Code Tasks", title: "[auto] Pool work",
            notes: nil, context: context, db: db)
        XCTAssertEqual(pool.lane, "auto")
        XCTAssertEqual(ProposalsInbox.tags(lane: pool.lane), ["auto"])
    }
}
