import XCTest
@testable import apple_tasks

final class ProposalsTests: XCTestCase {
    func testTagsAndMuteThreshold() {
        XCTAssertEqual(ProposalsInbox.tags(lane: nil), [])
        XCTAssertEqual(ProposalsInbox.tags(lane: ""), [])
        XCTAssertEqual(ProposalsInbox.tags(lane: "cursor"), ["auto", "cursor"])
        XCTAssertEqual(ProposalsInbox.lane(from: "lane:cursor"), "cursor")
        XCTAssertNil(ProposalsInbox.lane(from: nil))
        XCTAssertFalse(ProposalsInbox.shouldMute(accepted: 0, decided: 9))
        XCTAssertTrue(ProposalsInbox.shouldMute(accepted: 1, decided: 10))
        XCTAssertFalse(ProposalsInbox.shouldMute(accepted: 2, decided: 10))
    }

    func testDismissedProposalStaysQuietUntilEvidenceChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proposals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))

        XCTAssertEqual(ProposalsInbox.remember(
            detector: "model-snapshot", kind: "task", title: "Call Pat",
            evidence: "birthday tomorrow", lane: nil, db: db), "open")
        let row = try XCTUnwrap(db.findings(findingClass: "proposable", limit: 10).first)
        let dismissed = try ProposalsInbox.dismiss(id: row.id, muteDetector: false, db: db)
        XCTAssertEqual(dismissed.state, "dismissed")
        XCTAssertEqual(ProposalsInbox.remember(
            detector: "model-snapshot", kind: "task", title: "Call Pat",
            evidence: "birthday tomorrow", lane: nil, db: db), "quiet")
        XCTAssertEqual(db.finding(fingerprint: row.fingerprint)?.state, "dismissed")
        XCTAssertTrue(ProposalsInbox.list(db: db).proposals.isEmpty)

        XCTAssertEqual(ProposalsInbox.remember(
            detector: "model-snapshot", kind: "task", title: "Call Pat",
            evidence: "birthday is today", lane: "cursor", db: db), "refresh")
        let again = try XCTUnwrap(db.finding(fingerprint: row.fingerprint))
        XCTAssertEqual(again.state, "open")
        XCTAssertEqual(ProposalsInbox.lane(from: again.action), "cursor")
        XCTAssertEqual(ProposalsInbox.list(db: db).proposals.map(\.id), [again.id])
    }

    func testLowAcceptRateMutesTheDetector() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proposals-mute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))
        for index in 0..<10 {
            _ = ProposalsInbox.remember(
                detector: "model-snapshot", kind: "task", title: "Item \(index)",
                evidence: "reason \(index)", lane: nil, db: db)
        }
        for row in db.findings(findingClass: "proposable", limit: 20) {
            XCTAssertTrue(db.setFindingState(fingerprint: row.fingerprint, state: "dismissed"))
        }
        ProposalsInbox.considerMute(detector: "model-snapshot", db: db)
        XCTAssertTrue(ProposalsInbox.muted(db: db).contains("model-snapshot"))
        XCTAssertEqual(ProposalsInbox.mutedIssues(db: db).map(\.signature), ["muted:model-snapshot"])
        _ = ProposalsInbox.remember(
            detector: "model-snapshot", kind: "task", title: "Still there",
            evidence: "new", lane: nil, db: db)
        XCTAssertTrue(ProposalsInbox.list(db: db).proposals.isEmpty)
        ProposalsInbox.unmute("model-snapshot", db: db)
        XCTAssertEqual(ProposalsInbox.list(db: db).proposals.count, 1)
    }
}
