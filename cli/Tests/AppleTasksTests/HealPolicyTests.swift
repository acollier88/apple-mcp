import XCTest
@testable import apple_tasks

final class HealPolicyTests: XCTestCase {
    func testEscalationDoesNotRepeatARungWithoutNewEvidence() {
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "logs-oversize", rung: .playbook("logs-oversize"),
                              previous: nil, evidenceChanged: true, healsToday: 0, cap: 3),
            .playbook("logs-oversize"))
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "logs-oversize", rung: .playbook("logs-oversize"),
                              previous: "playbook", evidenceChanged: false, healsToday: 1, cap: 3),
            .quiet)
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "logs-oversize", rung: .playbook("logs-oversize"),
                              previous: "playbook", evidenceChanged: true, healsToday: 1, cap: 3),
            .agent)
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "homeassistant", rung: .agent,
                              previous: "agent", evidenceChanged: true, healsToday: 1, cap: 3),
            .needsHuman("homeassistant"))
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "binary-drift", rung: .needsHuman("binary-drift"),
                              previous: nil, evidenceChanged: true, healsToday: 0, cap: 3),
            .needsHuman("binary-drift"))
        XCTAssertEqual(
            HealPolicy.decide(fingerprint: "logs-oversize", rung: .playbook("logs-oversize"),
                              previous: nil, evidenceChanged: true, healsToday: 3, cap: 3),
            .breaker)
        XCTAssertEqual(HealPolicy.verified(clean: true), "healed")
        XCTAssertEqual(HealPolicy.verified(clean: false), "open")
    }

    func testReportListsOpenHealableFindingsOnly() {
        let rows = [
            AuditDB.FindingRow(id: 1, fingerprint: "logs-oversize", detector: "logs",
                               system: "disk", severity: "red", findingClass: "healable",
                               summary: "big", evidence: "big", evidenceHash: "a", action: nil,
                               state: "open", firstSeen: "t", lastSeen: "t", attempts: 2),
            AuditDB.FindingRow(id: 2, fingerprint: "homeassistant", detector: "homeassistant",
                               system: "homeassistant", severity: "red", findingClass: "healable",
                               summary: "ok", evidence: "ok", evidenceHash: "b", action: nil,
                               state: "healed", firstSeen: "t", lastSeen: "t", attempts: 1),
        ]
        let report = HealPolicy.report(rows) { $0 == "logs-oversize" ? "playbook" : nil }
        XCTAssertEqual(report.map(\.fingerprint), ["logs-oversize"])
        XCTAssertEqual(report.first?.level, "playbook")
        XCTAssertEqual(report.first?.attempts, 2)
    }

    func testCleanRecheckResetsTheLadder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heal-level-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))
        HealPolicy.remember(.agent, fingerprint: "launch-exit-1", db: db)
        XCTAssertEqual(HealPolicy.level("launch-exit-1", db: db), "agent")
        // A second agent attempt on new evidence escalates to a human.
        XCTAssertEqual(HealPolicy.decide(fingerprint: "launch-exit-1", rung: .agent,
                                         previous: HealPolicy.level("launch-exit-1", db: db),
                                         evidenceChanged: true, healsToday: 0, cap: 3),
                       .needsHuman("launch-exit-1"))
        HealPolicy.clear("launch-exit-1", db: db)
        XCTAssertNil(HealPolicy.level("launch-exit-1", db: db))
        // After a clean re-check the next occurrence starts at the bottom again.
        XCTAssertEqual(HealPolicy.decide(fingerprint: "launch-exit-1", rung: .agent,
                                         previous: HealPolicy.level("launch-exit-1", db: db),
                                         evidenceChanged: true, healsToday: 0, cap: 3),
                       .agent)
    }
}
