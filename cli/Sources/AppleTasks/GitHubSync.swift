import ArgumentParser
import EventKit
import Foundation

// IDEAS #50: two-way GitHub issue sync. Shells out to the `gh` CLI (auth,
// pagination, API churn are its problem — this stays keyless and dumb).
// Inbound: open issues assigned to you become tagged reminders with the
// issue URL in the url field (#19) and provenance in notes; the URL is the
// dedupe key. Outbound: a closed issue completes its reminder; a completed
// reminder closes its issue only behind --close-issues (mutating someone
// else's tracker by side effect must be opt-in).

struct GitHubSyncOut: Codable {
    let repo: String
    let issuesSeen: Int
    let created: [TaskOut]
    let completedReminders: [String]
    let closedIssues: [String]
    /// Completed reminders whose issues are still open, when --close-issues
    /// was NOT passed (nothing was done; rerun with the flag to close them).
    let wouldCloseIssues: [String]
    let unchanged: Int
    let dryRun: Bool
}

struct SyncGitHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-github",
        abstract: """
        Sync GitHub issues to a Reminders list via the gh CLI: assigned open \
        issues become [github]-tagged tasks (issue URL = dedupe key); closed \
        issues complete their reminders; --close-issues closes issues for \
        completed reminders.
        """
    )

    @Option(help: "GitHub repository, owner/repo.")
    var repo: String

    @Option(name: .customLong("list"), help: "Reminders list for created tasks (default \"Code Tasks\").")
    var listName: String = "Code Tasks"

    @Option(name: [.customShort("t"), .customLong("tag")],
            help: "Extra tag for created tasks (repeatable; [github] is always added).")
    var tags: [String] = []

    @Option(help: "Issue assignee filter passed to gh (default @me; \"all\" disables the filter).")
    var assignee: String = "@me"

    @Option(help: "Max issues fetched (default 50).")
    var limit: Int = 50

    @Flag(name: .customLong("close-issues"),
          help: "Close GitHub issues whose reminders are completed (outbound writes are opt-in).")
    var closeIssues = false

    @Flag(name: .customLong("dry-run"), help: "Report without creating, completing, or closing anything.")
    var dryRun = false

    private struct Issue: Decodable {
        let number: Int
        let title: String
        let url: String
        let body: String?
        let state: String
    }

    func run() async throws {
        for tag in tags { try Tags.validate(tag) }
        guard repo.contains("/") else {
            throw AppleTasksError.invalidInput("--repo must be owner/repo, got '\(repo)'")
        }

        var listArgs = ["issue", "list", "--repo", repo, "--state", "all",
                        "--limit", String(limit), "--json", "number,title,url,body,state"]
        if assignee.lowercased() != "all" {
            listArgs += ["--assignee", assignee]
        }
        let issues = try JSONDecoder().decode([Issue].self, from: Data(gh(listArgs).utf8))

        let store = Store()
        try await store.requestAccess()
        // All statuses: completed reminders drive the outbound close path.
        let reminders = await store.reminders(in: nil)
        let byURL = Dictionary(grouping: reminders) { $0.url?.absoluteString ?? "" }

        var created: [TaskOut] = []
        var completedReminders: [String] = []
        var closedIssues: [String] = []
        var wouldCloseIssues: [String] = []
        var unchanged = 0

        for issue in issues {
            let reminder = byURL[issue.url]?.first
            let issueOpen = issue.state.uppercased() == "OPEN"

            switch (reminder, issueOpen) {
            case (nil, true):
                // New assigned issue -> tagged reminder.
                if dryRun {
                    unchanged += 1
                    continue
                }
                let notes = "github:\(repo)#\(issue.number)\n\n"
                    + String((issue.body ?? "").prefix(1000))
                let out = try createTask(store: store, listName: listName, title: issue.title,
                                         tags: ["github"] + tags, notes: notes, due: nil,
                                         priority: nil, url: issue.url, recurrence: nil,
                                         mirrorNativeTags: true, auditCommand: "sync-github")
                created.append(out)
            case (nil, false):
                unchanged += 1
            case (let reminder?, false) where !reminder.isCompleted:
                // Issue closed elsewhere -> complete the reminder.
                if !dryRun {
                    reminder.isCompleted = true
                    try store.save(reminder)
                    AuditDB.shared.record(command: "sync-github", taskId: reminder.calendarItemExternalIdentifier,
                                          list: reminder.calendar?.title,
                                          detail: "completed (issue #\(issue.number) closed)")
                }
                completedReminders.append(reminder.calendarItemExternalIdentifier
                                          ?? reminder.calendarItemIdentifier)
            case (let reminder?, true) where reminder.isCompleted:
                // Reminder done -> close the issue, only when asked to.
                guard closeIssues else {
                    wouldCloseIssues.append(issue.url)
                    continue
                }
                if !dryRun {
                    _ = try gh(["issue", "close", issue.url,
                                "--comment", "Closed via apple-tasks sync (reminder completed)."])
                    AuditDB.shared.record(command: "sync-github", taskId: reminder.calendarItemExternalIdentifier,
                                          list: reminder.calendar?.title,
                                          detail: "closed issue #\(issue.number)")
                }
                closedIssues.append(issue.url)
            default:
                unchanged += 1
            }
        }

        emit(GitHubSyncOut(repo: repo, issuesSeen: issues.count, created: created,
                           completedReminders: completedReminders, closedIssues: closedIssues,
                           wouldCloseIssues: wouldCloseIssues, unchanged: unchanged, dryRun: dryRun))
    }

    /// Run gh and return stdout; a clean error mentions auth/install hints.
    private func gh(_ args: [String]) throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppleTasksError.automationFailed(
                "gh CLI not found (brew install gh; then gh auth login)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "gh failed"
            throw AppleTasksError.automationFailed(
                "gh \(args.prefix(2).joined(separator: " ")): \(detail)")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
