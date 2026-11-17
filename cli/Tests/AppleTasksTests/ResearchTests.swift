import XCTest
@testable import apple_tasks

final class ResearchTests: XCTestCase {
    func testGateRequiresGreenQuietAndAFreeSlot() {
        XCTAssertEqual(
            Proposals.gate(budget: nil, quiet: "inside", running: 0, maxConcurrent: 2),
            "budget snapshot missing or not green")
        XCTAssertEqual(
            Proposals.gate(budget: "yellow", quiet: "inside", running: 0, maxConcurrent: 2),
            "budget is yellow")
        XCTAssertEqual(
            Proposals.gate(budget: "green", quiet: "unconfigured", running: 0, maxConcurrent: 2),
            "quiet hours are not configured")
        XCTAssertEqual(
            Proposals.gate(budget: "green", quiet: "outside", running: 0, maxConcurrent: 2),
            "outside quiet hours")
        XCTAssertEqual(
            Proposals.gate(budget: "green", quiet: "inside", running: 2, maxConcurrent: 2),
            "no spare concurrency (2/2)")
        XCTAssertNil(Proposals.gate(budget: "green", quiet: "inside", running: 1, maxConcurrent: 2))
    }

    func testSpareBudgetAndQuietWindow() throws {
        let green = try budget(#"{"cursor":{"combine":"any","lanes":[{"id":"a","name":"a","percentUsed":10,"tier":"green","remainingPercent":90}]}}"#)
        XCTAssertEqual(Proposals.spareBudget(green), "green")
        let mixed = try budget(#"{"cursor":{"combine":"any","lanes":[{"id":"a","name":"a","percentUsed":10,"tier":"green","remainingPercent":90}]},"claude":{"combine":"all","lanes":[{"id":"b","name":"b","percentUsed":95,"tier":"red","remainingPercent":5}]}}"#)
        XCTAssertEqual(Proposals.spareBudget(mixed), "red")
        XCTAssertNil(Proposals.spareBudget(nil))

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(Proposals.quietState(TimeWindow(notBetween: ["00:00", "23:59"]), now: noon), "inside")
        XCTAssertEqual(Proposals.quietState(TimeWindow(notBetween: ["00:00", "00:01"]), now: noon), "outside")
        XCTAssertEqual(Proposals.quietState(nil, now: noon), "unconfigured")
    }

    func testLaneStreakBreaksOnSuccessAndSilenceNeedsOpenWork() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let runs = [
            Proposals.Run(id: 5, agent: "cursor", status: "failed"),
            Proposals.Run(id: 4, agent: "cursor", status: "timeout"),
            Proposals.Run(id: 3, agent: "cursor", status: "failed"),
            Proposals.Run(id: 2, agent: "cursor", status: "succeeded"),
            Proposals.Run(id: 1, agent: "claude", status: "failed"),
        ]
        let streak = Proposals.candidates(
            runs: runs, openAutoCount: 0, lastDispatchAt: now, now: now)
        XCTAssertEqual(streak.map(\.fingerprint), ["lane-streak:cursor"])
        XCTAssertFalse(streak[0].evidence.contains("succeeded"))

        let silent = Proposals.candidates(
            runs: [], openAutoCount: 2,
            lastDispatchAt: now.addingTimeInterval(-8 * 86400), now: now)
        XCTAssertEqual(silent.map(\.fingerprint), ["dispatcher-silent"])
        XCTAssertTrue(Proposals.candidates(
            runs: [], openAutoCount: 0, lastDispatchAt: nil, now: now).isEmpty)
    }

    func testDismissedProposalStaysQuietUntilTheEvidenceChanges() {
        let proposal = Proposals.Proposal(
            fingerprint: "lane-streak:cursor", detector: "lane-streak",
            title: "Proposal", evidence: "#5 failed")
        XCTAssertEqual(Proposals.decide(proposal, stored: nil), .record)
        XCTAssertEqual(
            Proposals.decide(proposal, stored: .init(evidenceHash: proposal.evidenceHash, status: "proposed")),
            .skip)
        XCTAssertEqual(
            Proposals.decide(proposal, stored: .init(evidenceHash: proposal.evidenceHash, status: "dismissed")),
            .skip)
        XCTAssertEqual(
            Proposals.decide(proposal, stored: .init(evidenceHash: "other", status: "dismissed")),
            .reopen)
    }

    func testProposalRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))
        XCTAssertTrue(db.saveProposal(
            fingerprint: "dispatcher-silent", detector: "dispatcher-silent",
            title: "Proposal: silent", evidence: "no dispatch rows",
            evidenceHash: "abc", status: "proposed"))
        XCTAssertEqual(db.proposal(fingerprint: "dispatcher-silent")?.status, "proposed")
        XCTAssertTrue(db.setProposalStatus(fingerprint: "dispatcher-silent", status: "dismissed"))
        XCTAssertEqual(db.proposals(status: "dismissed").count, 1)
        XCTAssertTrue(db.proposals(status: "proposed").isEmpty)
    }

    private func budget(_ providers: String) throws -> BudgetBandwidth {
        let json = #"{"schemaVersion":1,"updatedAt":"2026-11-16T00:00:00Z","providers":\#(providers)}"#
        return try JSONDecoder().decode(BudgetBandwidth.self, from: Data(json.utf8))
    }
}
