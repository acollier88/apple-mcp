import XCTest
@testable import apple_tasks

final class ResearchTests: XCTestCase {
    func testGateRequiresGreenQuietAndAFreeSlot() {
        XCTAssertEqual(
            ResearchDetectors.gate(budget: nil, quiet: "inside", running: 0, maxConcurrent: 2),
            "budget snapshot missing or not green")
        XCTAssertEqual(
            ResearchDetectors.gate(budget: "yellow", quiet: "inside", running: 0, maxConcurrent: 2),
            "budget is yellow")
        XCTAssertEqual(
            ResearchDetectors.gate(budget: "green", quiet: "unconfigured", running: 0, maxConcurrent: 2),
            "quiet hours are not configured")
        XCTAssertEqual(
            ResearchDetectors.gate(budget: "green", quiet: "outside", running: 0, maxConcurrent: 2),
            "outside quiet hours")
        XCTAssertEqual(
            ResearchDetectors.gate(budget: "green", quiet: "inside", running: 2, maxConcurrent: 2),
            "no spare concurrency (2/2)")
        XCTAssertNil(ResearchDetectors.gate(budget: "green", quiet: "inside", running: 1, maxConcurrent: 2))
    }

    func testSpareBudgetAndQuietWindow() throws {
        let green = try budget(#"{"cursor":{"combine":"any","lanes":[{"id":"a","name":"a","percentUsed":10,"tier":"green","remainingPercent":90}]}}"#)
        XCTAssertEqual(ResearchDetectors.spareBudget(green), "green")
        let mixed = try budget(#"{"cursor":{"combine":"any","lanes":[{"id":"a","name":"a","percentUsed":10,"tier":"green","remainingPercent":90}]},"claude":{"combine":"all","lanes":[{"id":"b","name":"b","percentUsed":95,"tier":"red","remainingPercent":5}]}}"#)
        XCTAssertEqual(ResearchDetectors.spareBudget(mixed), "red")
        XCTAssertNil(ResearchDetectors.spareBudget(nil))

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(ResearchDetectors.quietState(TimeWindow(notBetween: ["00:00", "23:59"]), now: noon), "inside")
        XCTAssertEqual(ResearchDetectors.quietState(TimeWindow(notBetween: ["00:00", "00:01"]), now: noon), "outside")
        XCTAssertEqual(ResearchDetectors.quietState(nil, now: noon), "unconfigured")
    }

    func testLaneStreakBreaksOnSuccessAndSilenceNeedsOpenWork() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let runs = [
            ResearchDetectors.Run(id: 5, agent: "cursor", status: "failed"),
            ResearchDetectors.Run(id: 4, agent: "cursor", status: "timeout"),
            ResearchDetectors.Run(id: 3, agent: "cursor", status: "failed"),
            ResearchDetectors.Run(id: 2, agent: "cursor", status: "succeeded"),
            ResearchDetectors.Run(id: 1, agent: "claude", status: "failed"),
        ]
        let streak = ResearchDetectors.candidates(
            runs: runs, openAutoCount: 0, lastDispatchAt: now, now: now)
        XCTAssertEqual(streak.map(\.fingerprint), ["lane-streak:cursor"])
        XCTAssertFalse(streak[0].evidence.contains("succeeded"))

        let silent = ResearchDetectors.candidates(
            runs: [], openAutoCount: 2,
            lastDispatchAt: now.addingTimeInterval(-8 * 86400), now: now)
        XCTAssertEqual(silent.map(\.fingerprint), ["dispatcher-silent"])
        XCTAssertTrue(ResearchDetectors.candidates(
            runs: [], openAutoCount: 0, lastDispatchAt: nil, now: now).isEmpty)
    }

    func testDismissedProposalStaysQuietUntilTheEvidenceChanges() {
        let proposal = ResearchDetectors.Proposal(
            fingerprint: "lane-streak:cursor", detector: "lane-streak",
            title: "Proposal", evidence: "#5 failed")
        XCTAssertEqual(ResearchDetectors.decide(proposal, stored: nil), .record)
        XCTAssertEqual(
            ResearchDetectors.decide(proposal, stored: .init(evidenceHash: proposal.evidenceHash, status: "proposed")),
            .skip)
        XCTAssertEqual(
            ResearchDetectors.decide(proposal, stored: .init(evidenceHash: proposal.evidenceHash, status: "dismissed")),
            .skip)
        XCTAssertEqual(
            ResearchDetectors.decide(proposal, stored: .init(evidenceHash: "other", status: "dismissed")),
            .reopen)
    }

    func testResearchProposalsShareTheInbox() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))
        XCTAssertEqual(ProposalsInbox.remember(
            detector: "dispatcher-silent", kind: "task", title: "Proposal: quiet 3",
            evidence: "open auto tasks 3", lane: nil, fingerprint: "dispatcher-silent", db: db), "open")
        let row = try XCTUnwrap(db.finding(fingerprint: "dispatcher-silent"))
        XCTAssertEqual(row.findingClass, "proposable")
        XCTAssertEqual(ProposalsInbox.list(db: db).proposals.map(\.fingerprint), ["dispatcher-silent"])
        _ = try ProposalsInbox.dismiss(id: row.id, muteDetector: false, db: db)
        // Same evidence after a dismissal stays quiet.
        XCTAssertEqual(ProposalsInbox.remember(
            detector: "dispatcher-silent", kind: "task", title: "Proposal: quiet 3",
            evidence: "open auto tasks 3", lane: nil, fingerprint: "dispatcher-silent", db: db), "quiet")
        // Doctor's close-out never touches proposals.
        XCTAssertTrue(db.resolveFindings(notSeen: []).isEmpty)
    }

    private func budget(_ providers: String) throws -> BudgetBandwidth {
        let json = #"{"schemaVersion":1,"updatedAt":"2026-11-16T00:00:00Z","providers":\#(providers)}"#
        return try JSONDecoder().decode(BudgetBandwidth.self, from: Data(json.utf8))
    }
}
