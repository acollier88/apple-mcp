import XCTest
@testable import apple_tasks

final class FindingsTests: XCTestCase {
    func testHomeAssistantAndHermesDetectors() {
        XCTAssertNil(Findings.homeAssistant(status: "origin http://ha.local:8123; api ok"))
        let ha = Findings.homeAssistant(status: "unreachable (timeout)")
        XCTAssertEqual(ha?.kind, .healable)
        XCTAssertEqual(ha?.fingerprint, "homeassistant")

        XCTAssertFalse(Findings.cronIsHealable("jobs: error provider=ollama-launch Copilot 403"))
        XCTAssertTrue(Findings.cronIsHealable("backup: error exit 1"))
        let hermes = Findings.hermes(
            status: "present", gateway: "not running", cron: "0 jobs",
            haLink: "connected", haDown: false)
        XCTAssertEqual(hermes?.fingerprint, "hermes")
        XCTAssertNil(Findings.hermes(
            status: "present", gateway: "running", cron: "0 jobs",
            haLink: "connected", haDown: false))
    }

    func testSameEvidenceStaysQuietUntilItChanges() {
        let first = Findings.homeAssistant(status: "unreachable")!
        XCTAssertEqual(Findings.decide(evidenceHash: first.evidenceHash, stored: nil), .open)
        XCTAssertEqual(
            Findings.decide(evidenceHash: first.evidenceHash,
                            stored: .init(evidenceHash: first.evidenceHash, state: "dismissed")),
            .quiet)
        let changed = Findings.homeAssistant(status: "HTTP 401")!
        XCTAssertEqual(
            Findings.decide(evidenceHash: changed.evidenceHash,
                            stored: .init(evidenceHash: first.evidenceHash, state: "open")),
            .refresh)
        XCTAssertFalse(Findings.shouldEnqueue(decision: .quiet, createdToday: 0, dailyCap: 3))
        XCTAssertFalse(Findings.shouldEnqueue(decision: .open, createdToday: 3, dailyCap: 3))
        XCTAssertTrue(Findings.shouldEnqueue(decision: .refresh, createdToday: 1, dailyCap: 3))
        XCTAssertEqual(Findings.sink(for: .healable), .heal)
        XCTAssertEqual(Findings.sink(for: .proposable), .proposed)
        XCTAssertEqual(Findings.sink(for: .needsHuman), .needsHuman)
    }

    func testFindingRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("findings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("t.db"))
        XCTAssertEqual(db.observeFinding(
            fingerprint: "homeassistant", detector: "homeassistant", system: "homeassistant",
            severity: "red", findingClass: "healable", summary: "down", evidence: "down",
            evidenceHash: "aaa", action: "fix"), "open")
        XCTAssertEqual(db.observeFinding(
            fingerprint: "homeassistant", detector: "homeassistant", system: "homeassistant",
            severity: "red", findingClass: "healable", summary: "down", evidence: "down",
            evidenceHash: "aaa", action: "fix"), "quiet")
        XCTAssertEqual(db.observeFinding(
            fingerprint: "homeassistant", detector: "homeassistant", system: "homeassistant",
            severity: "red", findingClass: "healable", summary: "worse", evidence: "worse",
            evidenceHash: "bbb", action: "fix"), "refresh")
        XCTAssertEqual(db.finding(fingerprint: "homeassistant")?.state, "open")
        XCTAssertEqual(db.finding(fingerprint: "homeassistant")?.attempts, 1)
        XCTAssertTrue(db.setFindingState(fingerprint: "homeassistant", state: "dismissed"))
        XCTAssertEqual(db.findings(state: "open").count, 0)
        XCTAssertEqual(db.findings(state: "dismissed").count, 1)
    }

    func testUndetectedFindingsCloseAndRecurrencesReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("findings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = AuditDB(url: dir.appendingPathComponent("test.db"))
        func observe(_ fp: String, _ evidence: String) -> String {
            db.observeFinding(fingerprint: fp, detector: fp, system: "s", severity: "yellow",
                              findingClass: "healable", summary: fp, evidence: evidence,
                              evidenceHash: evidence, action: nil)
        }
        XCTAssertEqual(observe("disk", "90%"), "open")
        XCTAssertEqual(observe("launchd", "exit 1"), "open")
        XCTAssertEqual(observe("disk", "90%"), "quiet")
        // This run only saw "disk": launchd came back clean.
        XCTAssertEqual(db.resolveFindings(notSeen: ["disk"]), ["launchd"])
        XCTAssertEqual(db.finding(fingerprint: "launchd")?.state, "healed")
        // Same evidence again after it was healed is a recurrence, not quiet.
        XCTAssertEqual(observe("launchd", "exit 1"), "refresh")
        XCTAssertEqual(db.finding(fingerprint: "launchd")?.state, "open")
    }
}
