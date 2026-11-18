import XCTest
@testable import apple_tasks

final class DispatchQuietTests: XCTestCase {
    private func report(_ action: String, taskId: String = "t1") -> Dispatch.DispatchReport {
        Dispatch.DispatchReport(
            taskId: taskId, title: "title", agent: "cursor", cwd: nil,
            action: action, exitCode: nil, runLog: nil, worktree: nil)
    }

    private func assertSilent(
        _ reports: [Dispatch.DispatchReport],
        quiet: Bool,
        lastReportHash: String?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emission = Dispatch.reportEmission(reports: reports, quiet: quiet, lastReportHash: lastReportHash)
        guard case .silent = emission else {
            return XCTFail("\(message): expected silence, got \(emission)", file: file, line: line)
        }
    }

    private func assertEmits(
        _ reports: [Dispatch.DispatchReport],
        quiet: Bool,
        lastReportHash: String?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emission = Dispatch.reportEmission(reports: reports, quiet: quiet, lastReportHash: lastReportHash)
        guard case .emit = emission else {
            return XCTFail("\(message): expected emit, got silence", file: file, line: line)
        }
    }

    func testQuietEmptyPassPrintsNothing() {
        assertSilent([], quiet: true, lastReportHash: nil, "first idle pass")
        assertSilent([], quiet: true, lastReportHash: "abc", "idle pass after other work")
        let emptyHash = Dispatch.reportHash([])
        assertSilent([], quiet: true, lastReportHash: emptyHash, "repeated idle pass")
    }

    func testQuietRepeatedNoisePrintsNothing() {
        let reports = [
            report("gc: removed worktree", taskId: "wt"),
            report("skipped: no agent", taskId: "a"),
            report("gated: quiet hours", taskId: "b"),
            report("scheduled: not yet", taskId: "c"),
        ]
        let hash = Dispatch.reportHash(reports)
        assertSilent(reports, quiet: true, lastReportHash: hash, "identical noise")
        // Order does not matter: the hash sorts action+taskId.
        let shuffled = [reports[2], reports[0], reports[3], reports[1]]
        assertSilent(shuffled, quiet: true, lastReportHash: hash, "reordered noise")
    }

    func testQuietFirstNoiseStillPrints() {
        let reports = [report("skipped: waiting on claim")]
        assertEmits(reports, quiet: true, lastReportHash: nil, "first skip")
        assertEmits(reports, quiet: true, lastReportHash: "different", "changed skip")
    }

    func testQuietRealOutcomesAlwaysPrint() {
        for action in ["failed", "timeout", "succeeded", "spawn failed: absent", "succeeded (open, claim shed)"] {
            let reports = [report(action)]
            assertEmits(reports, quiet: true, lastReportHash: nil, action)
            assertEmits(reports, quiet: true, lastReportHash: Dispatch.reportHash(reports), action + " even when hash matches")
        }
    }

    func testQuietSkippedLedgerIsNotNoise() {
        let reports = [report("skipped: ledger row running")]
        let hash = Dispatch.reportHash(reports)
        assertEmits(reports, quiet: true, lastReportHash: hash, "ledger skip is a real line")
    }

    func testQuietNoisePlusFailurePrints() {
        let reports = [
            report("gc: pruned", taskId: "wt"),
            report("failed", taskId: "task"),
        ]
        assertEmits(reports, quiet: true, lastReportHash: Dispatch.reportHash(reports), "failure alongside noise")
    }

    func testNonQuietStillPrintsIdleAndRepeatNoise() {
        assertEmits([], quiet: false, lastReportHash: nil, "interactive empty pass")
        let reports = [report("gc: removed worktree")]
        assertEmits(reports, quiet: false, lastReportHash: Dispatch.reportHash(reports), "interactive repeat")
    }
}
