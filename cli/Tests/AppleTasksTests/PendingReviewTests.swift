import Foundation
import XCTest
@testable import apple_tasks

final class PendingReviewTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-pr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testUnmergedBranchListedThenMergedIsReviewed() throws {
        let fixture = try makeFixture(agent: "cursor")
        let items = PendingReview.items(db: fixture.db)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].commitsAhead, 1)
        XCTAssertEqual(items[0].commits.count, 1)
        XCTAssertEqual(items[0].branch, fixture.branch)
        XCTAssertEqual(items[0].agent, "cursor")
        XCTAssertNil(fixture.db.dispatchRow(id: fixture.id)?.reviewedAt)

        try git(["merge", fixture.branch], repo: fixture.repo)
        let after = PendingReview.items(db: fixture.db)
        XCTAssertTrue(after.isEmpty)
        XCTAssertNotNil(fixture.db.dispatchRow(id: fixture.id)?.reviewedAt)
    }

    func testDeletedBranchIsMarkedReviewed() throws {
        let fixture = try makeFixture(agent: "cursor")
        try git(["worktree", "remove", "--force", fixture.worktree], repo: fixture.repo)
        try git(["branch", "-D", fixture.branch], repo: fixture.repo)

        let items = PendingReview.items(db: fixture.db)
        XCTAssertTrue(items.isEmpty)
        let row = fixture.db.dispatchRow(id: fixture.id)
        XCTAssertNotNil(row?.reviewedAt)
        XCTAssertNil(row?.worktree, "gone worktree dir should be cleared")
    }

    func testDiscardRemovesWorktreeAndBranch() throws {
        let fixture = try makeFixture(agent: "cursor")
        guard let row = fixture.db.dispatchRow(id: fixture.id) else {
            return XCTFail("missing ledger row")
        }

        let result = DispatchDiscard.discard(row: row, db: fixture.db)
        XCTAssertEqual(result.id, Int(fixture.id))
        XCTAssertEqual(result.branch, fixture.branch)
        XCTAssertTrue(result.worktreeRemoved)
        XCTAssertTrue(result.branchDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktree))
        XCTAssertNotEqual(
            Dispatch.runGit(["rev-parse", "--verify", "--quiet", fixture.branch],
                            repo: fixture.repo), 0)
        let after = fixture.db.dispatchRow(id: fixture.id)
        XCTAssertNotNil(after?.reviewedAt)
        XCTAssertNil(after?.worktree)
        XCTAssertTrue(PendingReview.items(db: fixture.db).isEmpty)
    }

    func testAgeLabelAndDigestLine() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z"))
        XCTAssertEqual(
            PendingReviewItem.ageLabel(finishedAt: "2026-11-13T12:00:00Z", now: now), "3d old")
        XCTAssertEqual(
            PendingReviewItem.ageLabel(finishedAt: "2026-11-16T10:00:00Z", now: now), "2h old")
        XCTAssertEqual(
            PendingReviewItem.ageLabel(finishedAt: "2026-11-16T11:30:00Z", now: now), "30m old")
        XCTAssertEqual(
            PendingReviewItem.ageLabel(finishedAt: "2026-11-16T11:59:30Z", now: now), "just now")
        XCTAssertEqual(PendingReviewItem.ageLabel(finishedAt: nil, now: now), "age unknown")
        XCTAssertEqual(PendingReviewItem.ageLabel(finishedAt: "nope", now: now), "age unknown")

        let fixture = try makeFixture(agent: "cursor")
        let items = PendingReview.items(db: fixture.db)
        let line = Digest.pendingReviewLine(items[0])
        XCTAssertEqual(items[0].age, PendingReviewItem.ageLabel(finishedAt: items[0].finishedAt))
        XCTAssertTrue(line.contains(items[0].age))
        XCTAssertTrue(line.contains("#\(items[0].id)"))
        XCTAssertTrue(line.contains("1 commit"))
        let summary = Digest.pushSummary(DigestOut(
            since: "t", generatedAt: "t", dispatches: [], pendingReview: items,
            auditActions: 0, auditByCommand: [:], dueToday: [], events: [],
            noteCreated: nil, pushed: nil))
        XCTAssertTrue(summary.contains("1 awaiting review"))
        XCTAssertTrue(summary.contains("oldest \(items[0].age)"))
    }

    func testPendingReviewNotificationDedupesUntilTheBranchChanges() throws {
        let fixture = try makeFixture(agent: "cursor")
        let items = PendingReview.items(db: fixture.db)
        let first = PendingReview.notifyPlan(items: items, previousSignature: nil)
        XCTAssertTrue(first.shouldNotify)
        XCTAssertTrue(first.signature.contains(fixture.branch))
        XCTAssertTrue(first.signature.contains(String(fixture.id)))
        XCTAssertTrue(first.body.contains(items[0].age))

        let again = PendingReview.notifyPlan(items: items, previousSignature: first.signature)
        XCTAssertFalse(again.shouldNotify)
        XCTAssertEqual(again.signature, first.signature)

        let cleared = PendingReview.notifyPlan(items: [], previousSignature: first.signature)
        XCTAssertFalse(cleared.shouldNotify)
        XCTAssertNotEqual(cleared.signature, first.signature)

        let returned = PendingReview.notifyPlan(items: items, previousSignature: cleared.signature)
        XCTAssertTrue(returned.shouldNotify)

        try "more\n".write(to: URL(fileURLWithPath: fixture.worktree).appendingPathComponent("MORE"),
                           atomically: true, encoding: .utf8)
        try git(["add", "MORE"], repo: fixture.worktree)
        try git(["commit", "-m", "more work"], repo: fixture.worktree)
        let later = PendingReview.items(db: fixture.db)
        let changed = PendingReview.notifyPlan(items: later, previousSignature: first.signature)
        XCTAssertTrue(changed.shouldNotify)
        XCTAssertNotEqual(changed.signature, first.signature)
        XCTAssertEqual(later[0].commitsAhead, 2)
    }

    func testAcceptPlanChoosesMergeOrPullRequestWithoutNetwork() {
        XCTAssertEqual(
            DispatchAccept.plan(fastForward: true, clean: true),
            DispatchAccept.Plan(action: .merge, reason: "clean fast-forward"))
        XCTAssertEqual(
            DispatchAccept.plan(fastForward: false, clean: true),
            DispatchAccept.Plan(action: .pullRequest, reason: "not a fast-forward of HEAD"))
        XCTAssertEqual(
            DispatchAccept.plan(fastForward: false, clean: false),
            DispatchAccept.Plan(action: .pullRequest, reason: "not a fast-forward of HEAD"))
        XCTAssertEqual(
            DispatchAccept.plan(fastForward: true, clean: false),
            DispatchAccept.Plan(action: .pullRequest, reason: "working tree is not clean"))
        XCTAssertEqual(
            DispatchAccept.gitPushArguments(branch: "agent/cursor-1"),
            ["push", "-u", "origin", "--", "agent/cursor-1"])
        XCTAssertEqual(
            DispatchAccept.ghPullRequestArguments(
                branch: "agent/cursor-1", base: "main", title: "t", body: "b"),
            ["pr", "create", "--head", "agent/cursor-1", "--title", "t", "--body", "b", "--base", "main"])
        XCTAssertEqual(
            DispatchAccept.firstURL(in: "https://github.com/acollier88/apple-mcp/pull/1\n"),
            "https://github.com/acollier88/apple-mcp/pull/1")
    }

    func testAcceptFastForwardMergesInATemporaryRepo() throws {
        let fixture = try makeFixture(agent: "cursor")
        guard let row = fixture.db.dispatchRow(id: fixture.id) else {
            return XCTFail("missing ledger row")
        }
        let headBefore = try git(["rev-parse", "HEAD"], repo: fixture.repo)
        guard case .accepted(let dry) = try DispatchAccept.accept(row: row, db: fixture.db, dryRun: true) else {
            return XCTFail("expected a dry-run decision")
        }
        XCTAssertEqual(dry.action, "merge")
        XCTAssertEqual(dry.reason, "clean fast-forward")
        XCTAssertTrue(dry.dryRun)
        XCTAssertFalse(dry.merged)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], repo: fixture.repo), headBefore)
        XCTAssertNil(fixture.db.dispatchRow(id: fixture.id)?.reviewedAt)

        guard case .accepted(let merged) = try DispatchAccept.accept(row: row, db: fixture.db, dryRun: false) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(merged.action, "merge")
        XCTAssertTrue(merged.merged)
        XCTAssertTrue(merged.worktreeRemoved)
        XCTAssertTrue(merged.branchDeleted)
        XCTAssertFalse(merged.dryRun)
        XCTAssertNil(merged.pullRequestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktree))
        XCTAssertNotEqual(
            Dispatch.runGit(["rev-parse", "--verify", "--quiet", fixture.branch], repo: fixture.repo), 0)
        let tip = try git(["rev-parse", "HEAD"], repo: fixture.repo)
        XCTAssertNotEqual(tip, headBefore)
        let after = fixture.db.dispatchRow(id: fixture.id)
        XCTAssertNotNil(after?.reviewedAt)
        XCTAssertNil(after?.worktree)
        XCTAssertTrue(PendingReview.items(db: fixture.db).isEmpty)

        guard case .alreadyReviewed(let second) = try DispatchAccept.accept(
            row: fixture.db.dispatchRow(id: fixture.id)!, db: fixture.db, dryRun: false) else {
            return XCTFail("second accept should be a no-op")
        }
        XCTAssertFalse(second.accepted)
        XCTAssertEqual(second.note, "already reviewed")
    }

    func testAcceptDryRunDoesNotMergeADivergedOrDirtyTemporaryRepo() throws {
        let diverged = try makeFixture(agent: "cursor")
        try "main-only\n".write(
            to: URL(fileURLWithPath: diverged.repo).appendingPathComponent("README"),
            atomically: true, encoding: .utf8)
        try git(["add", "README"], repo: diverged.repo)
        try git(["commit", "-m", "diverge"], repo: diverged.repo)
        let probe = DispatchAccept.probe(branch: diverged.branch, repo: diverged.repo)
        XCTAssertTrue(probe.branchExists)
        XCTAssertFalse(probe.alreadyMerged)
        XCTAssertFalse(probe.fastForward)
        XCTAssertTrue(probe.clean)
        XCTAssertEqual(
            DispatchAccept.plan(fastForward: probe.fastForward, clean: probe.clean).action,
            .pullRequest)
        guard let row = diverged.db.dispatchRow(id: diverged.id) else {
            return XCTFail("missing ledger row")
        }
        let head = try git(["rev-parse", "HEAD"], repo: diverged.repo)
        guard case .accepted(let decision) = try DispatchAccept.accept(row: row, db: diverged.db, dryRun: true) else {
            return XCTFail("expected a dry-run decision")
        }
        XCTAssertEqual(decision.action, "pull-request")
        XCTAssertEqual(decision.reason, "not a fast-forward of HEAD")
        XCTAssertTrue(decision.dryRun)
        XCTAssertFalse(decision.merged)
        XCTAssertNil(decision.pullRequestURL)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], repo: diverged.repo), head)
        XCTAssertNil(diverged.db.dispatchRow(id: diverged.id)?.reviewedAt)
        XCTAssertEqual(
            Dispatch.runGit(["rev-parse", "--verify", "--quiet", diverged.branch], repo: diverged.repo), 0)

        let dirty = try makeFixture(agent: "claude")
        try "dirty\n".write(
            to: URL(fileURLWithPath: dirty.repo).appendingPathComponent("DIRTY"),
            atomically: true, encoding: .utf8)
        let dirtyProbe = DispatchAccept.probe(branch: dirty.branch, repo: dirty.repo)
        XCTAssertTrue(dirtyProbe.fastForward)
        XCTAssertFalse(dirtyProbe.clean)
        guard let dirtyRow = dirty.db.dispatchRow(id: dirty.id) else {
            return XCTFail("missing ledger row")
        }
        guard case .accepted(let dirtyDecision) = try DispatchAccept.accept(
            row: dirtyRow, db: dirty.db, dryRun: true) else {
            return XCTFail("expected a dry-run decision")
        }
        XCTAssertEqual(dirtyDecision.action, "pull-request")
        XCTAssertEqual(dirtyDecision.reason, "working tree is not clean")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.worktree))
        XCTAssertNil(dirty.db.dispatchRow(id: dirty.id)?.reviewedAt)
    }

    func testAgeOutRemovesWorktreeAndKeepsTheBranch() throws {
        let fixture = try makeFixture(agent: "cursor")
        guard let row = fixture.db.dispatchRow(id: fixture.id) else {
            return XCTFail("missing ledger row")
        }
        let young = Dispatch.ageOutPendingReviewWorktree(
            worktree: fixture.worktree, branch: fixture.branch, repo: fixture.repo,
            finishedAt: row.finishedAt, keepDays: 14, now: Date())
        XCTAssertNil(young)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.worktree))

        let disabled = Dispatch.ageOutPendingReviewWorktree(
            worktree: fixture.worktree, branch: fixture.branch, repo: fixture.repo,
            finishedAt: "2020-01-01T00:00:00Z", keepDays: 0, now: Date())
        XCTAssertNil(disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.worktree))

        let later = Date().addingTimeInterval(10 * 86_400)
        let action = Dispatch.ageOutPendingReviewWorktree(
            worktree: fixture.worktree, branch: fixture.branch, repo: fixture.repo,
            finishedAt: row.finishedAt, keepDays: 7, now: later)
        XCTAssertEqual(
            action,
            "gc: removed pending-review worktree (>7d), branch \(fixture.branch) kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktree))
        XCTAssertEqual(
            Dispatch.runGit(["rev-parse", "--verify", "--quiet", fixture.branch], repo: fixture.repo), 0)
        XCTAssertNotNil(fixture.db.dispatchRow(id: fixture.id)?.worktree,
                        "age-out itself does not clear the ledger column")
        XCTAssertTrue(Dispatch.retainPendingWorktreeRecord(
            status: "succeeded", reviewedAt: nil, branchExists: true))
        XCTAssertFalse(Dispatch.retainPendingWorktreeRecord(
            status: "succeeded", reviewedAt: nil, branchExists: false))
        XCTAssertFalse(Dispatch.retainPendingWorktreeRecord(
            status: "succeeded", reviewedAt: "2026-11-16T00:00:00Z", branchExists: true))
        XCTAssertFalse(Dispatch.retainPendingWorktreeRecord(
            status: "failed", reviewedAt: nil, branchExists: true))
    }

    func testPendingReviewWorktreeDaysDecodesAsOptIn() throws {
        let absent = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{}}"#.utf8))
        XCTAssertNil(absent.pendingReviewWorktreeDays)
        let off = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{},"pendingReviewWorktreeDays":0}"#.utf8))
        XCTAssertEqual(off.pendingReviewWorktreeDays, 0)
        let on = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(#"{"agents":{},"pendingReviewWorktreeDays":14}"#.utf8))
        XCTAssertEqual(on.pendingReviewWorktreeDays, 14)
    }

    // MARK: - harness

    private struct Fixture {
        let db: AuditDB
        let repo: String
        let worktree: String
        let branch: String
        let id: Int64
    }

    private func makeFixture(agent: String) throws -> Fixture {
        let root = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let wtURL = root.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let repo = repoURL.path
        try git(["init", "-b", "main"], repo: repo)
        try git(["config", "user.name", "Test"], repo: repo)
        try git(["config", "user.email", "test@example.com"], repo: repo)
        try git(["config", "commit.gpgsign", "false"], repo: repo)
        try "base\n".write(to: repoURL.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "README"], repo: repo)
        try git(["commit", "-m", "init"], repo: repo)

        let db = AuditDB(url: root.appendingPathComponent("test.db"))
        XCTAssertTrue(db.isAvailable)
        let claim = db.claimDispatch(taskId: "task-review", agent: agent,
                                     command: "echo", cwd: repo)
        guard case .claimed(let id) = claim else {
            XCTFail("expected claimed, got \(claim)")
            throw NSError(domain: "PendingReviewTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "claim failed: \(claim)"])
        }
        let branch = "agent/\(agent)-\(id)"
        try git(["worktree", "add", "-b", branch, wtURL.path], repo: repo)
        try "work\n".write(to: wtURL.appendingPathComponent("CHANGE"), atomically: true, encoding: .utf8)
        try git(["add", "CHANGE"], repo: wtURL.path)
        try git(["commit", "-m", "work"], repo: wtURL.path)

        db.setDispatchPaths(id: id, runLogPath: nil, worktree: wtURL.path)
        XCTAssertTrue(db.finishDispatch(id: id, status: "succeeded", exitCode: 0,
                                        summary: "pending review fixture"))
        return Fixture(db: db, repo: repo, worktree: wtURL.path, branch: branch, id: id)
    }

    @discardableResult
    private func git(_ args: [String], repo: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "PendingReviewTests.git", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(stderr)\(stdout)"])
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
