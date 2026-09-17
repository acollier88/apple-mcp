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

    // MARK: - harness

    private struct Fixture {
        let db: AuditDB
        let repo: String
        let worktree: String
        let branch: String
        let id: Int64
    }

    private func makeFixture(agent: String) throws -> Fixture {
        let repoURL = tempDir.appendingPathComponent("repo", isDirectory: true)
        let wtURL = tempDir.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let repo = repoURL.path
        try git(["init", "-b", "main"], repo: repo)
        try git(["config", "user.name", "Test"], repo: repo)
        try git(["config", "user.email", "test@example.com"], repo: repo)
        try git(["config", "commit.gpgsign", "false"], repo: repo)
        try "base\n".write(to: repoURL.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "README"], repo: repo)
        try git(["commit", "-m", "init"], repo: repo)

        let db = AuditDB(url: tempDir.appendingPathComponent("test.db"))
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
