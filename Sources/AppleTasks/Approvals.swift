import ArgumentParser
import Foundation

// IDEAS #39: ntfy approvals — actionable human-in-the-loop. `approve
// request` pushes a notification with [Approve] [Deny] buttons; the buttons
// POST "approve <token>" / "deny <token>" to a REPLY topic on the ntfy
// server (the phone can't reach the Mac, so the server carries the answer).
// `approve check` polls the reply topic and records the verdict in the
// approvals table; `approve answer` is the Mac-side path (and the escape
// hatch when a push was quiet-hours suppressed). First answer wins.
//
// Trust model: whoever knows the reply topic name can answer, exactly like
// the main ntfy topic's trust model — topics are the secret. Keep both
// unguessable. The audit table records every request and answer with caller.

struct ApprovalOut: Codable {
    let token: String
    let question: String
    let taskId: String?
    let status: String
    let requestedAt: String
    let expiresAt: String?
    let answeredAt: String?
    let answeredVia: String?
    /// request only: the quiet-hours window ("22:00–07:00") that held the
    /// push. The request row still exists — answer with 'approve answer'
    /// or find it in 'approve list'; the push simply never fired.
    var pushSuppressed: String?

    init(_ row: AuditDB.ApprovalRow, pushSuppressed: String? = nil) {
        token = row.token
        question = row.question
        taskId = row.taskId
        status = row.status
        requestedAt = row.requestedAt
        expiresAt = row.expiresAt
        answeredAt = row.answeredAt
        answeredVia = row.answeredVia
        self.pushSuppressed = pushSuppressed
    }
}

enum ApprovalTopics {
    /// Reply topic carrying button answers. Defaults to "<topic>-approvals";
    /// override with "approvalsReplyTopic" in notify.json.
    static func resolve() throws -> (server: String, topic: String, replyTopic: String) {
        guard let config = NotifyConfig.load(), let ntfy = config.ntfy else {
            throw AppleTasksError.saveFailed(
                "approvals need ntfy configured: {\"ntfy\": {\"topic\": \"...\"}} at \(NotifyConfig.url.path)")
        }
        return (ntfy.server ?? "https://ntfy.sh", ntfy.topic,
                config.approvalsReplyTopic ?? "\(ntfy.topic)-approvals")
    }
}

struct Approve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Human-in-the-loop approvals over ntfy: request with Approve/Deny buttons, check/wait for the answer.",
        subcommands: [ApproveRequest.self, ApproveCheck.self, ApproveAnswer.self, ApproveList.self]
    )
}

struct ApproveRequest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request",
        abstract: """
        Push an approval request with [Approve] [Deny] buttons and emit its \
        token. The push respects quietHours (notify.json) unless --force; a \
        suppressed request still exists and can be answered with 'approve \
        answer' or seen in 'approve list'.
        """
    )

    @Argument(help: "What is being asked, e.g. 'Send the reply draft to Sarah?'")
    var question: String

    @Option(name: .customLong("task"), help: "Task id this approval belongs to (for the audit trail).")
    var taskId: String?

    @Option(name: .customLong("expires-minutes"), help: "Pending requests expire after this long (default 240).")
    var expiresMinutes: Int = 240

    @Flag(help: "Priority: push even during quietHours.")
    var force = false

    func run() async throws {
        let (server, topic, replyTopic) = try ApprovalTopics.resolve()
        let token = UUID().uuidString.prefix(8).lowercased()
        let iso = ISO8601DateFormatter()
        let expiresAt = iso.string(from: Date().addingTimeInterval(TimeInterval(expiresMinutes) * 60))

        AuditDB.shared.createApproval(token: String(token), taskId: taskId,
                                      question: question, expiresAt: expiresAt)
        AuditDB.shared.record(command: "approve request", taskId: taskId, detail: "\(token): \(question)")

        var suppressed: String?
        if !force, let quiet = NotifyConfig.load()?.quietHours,
           case .inside(let window) = quiet.check() {
            suppressed = window
            AuditDB.shared.record(command: "approve request", taskId: taskId,
                                  detail: token.description, result: "push suppressed (quiet hours \(window))")
        } else {
            try await Self.push(server: server, topic: topic, replyTopic: replyTopic,
                                token: String(token), question: question, taskId: taskId)
        }

        guard let row = AuditDB.shared.approvalRows(token: String(token)).first else {
            throw AppleTasksError.saveFailed("approval row vanished after insert (db unwritable?)")
        }
        emit(ApprovalOut(row, pushSuppressed: suppressed))
    }

    /// ntfy JSON publish (POST to the server root) — the only publish form
    /// that carries action buttons cleanly.
    static func push(server: String, topic: String, replyTopic: String,
                     token: String, question: String, taskId: String?) async throws {
        struct Action: Codable {
            let action = "http"
            let label: String
            let url: String
            let method = "POST"
            let body: String
            let clear = true
        }
        struct Publish: Codable {
            let topic: String
            let title: String
            let message: String
            let priority = 4
            let tags = ["raised_hand"]
            let actions: [Action]
        }
        let replyURL = "\(server)/\(replyTopic)"
        let publish = Publish(
            topic: topic,
            title: "Agent approval needed" + (taskId.map { " (task \($0.prefix(8))…)" } ?? ""),
            message: question + "\n[\(token)]",
            actions: [
                Action(label: "Approve", url: replyURL, body: "approve \(token)"),
                Action(label: "Deny", url: replyURL, body: "deny \(token)"),
            ])

        guard let url = URL(string: server) else {
            throw AppleTasksError.saveFailed("bad ntfy server URL: \(server)")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(publish)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppleTasksError.automationFailed("ntfy publish failed (\(server))")
        }
    }
}

struct ApproveCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: """
        Report an approval's status, polling the ntfy reply topic for a \
        button answer first. --wait-seconds blocks until answered, expired, \
        or the wait elapses (poll every 3s) — the shape an agent mid-run \
        wants: request, then check --wait-seconds 600, then act or stop.
        """
    )

    @Argument(help: "Token from 'approve request'.")
    var token: String

    @Option(name: .customLong("wait-seconds"), help: "Keep polling this long for an answer (default: one poll, no wait).")
    var waitSeconds: Int = 0

    func run() async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while true {
            let row = try await Self.refresh(token: token)
            if row.status != "pending" || Date() >= deadline {
                emit(ApprovalOut(row))
                return
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// One poll pass: expire overdue rows, then scan the reply topic for
    /// "approve <token>" / "deny <token>" since the request was made.
    static func refresh(token: String) async throws -> AuditDB.ApprovalRow {
        guard let row = AuditDB.shared.approvalRows(token: token).first else {
            throw AppleTasksError.saveFailed("no approval with token '\(token)'")
        }
        guard row.status == "pending" else { return row }

        let iso = ISO8601DateFormatter()
        if let expires = row.expiresAt, let expiresDate = iso.date(from: expires), Date() > expiresDate {
            _ = AuditDB.shared.answerApproval(token: token, status: "expired", via: "timeout")
            AuditDB.shared.record(command: "approve expire", taskId: row.taskId, detail: token)
            return AuditDB.shared.approvalRows(token: token).first ?? row
        }

        let (server, _, replyTopic) = try ApprovalTopics.resolve()
        let since = iso.date(from: row.requestedAt).map { Int($0.timeIntervalSince1970) } ?? 0
        guard let url = URL(string: "\(server)/\(replyTopic)/json?poll=1&since=\(since)") else { return row }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("apple-tasks/0.1 (+approvals)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            return row // poll failure leaves the row pending; next check retries
        }
        if ProcessInfo.processInfo.environment["APPROVE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("poll \(url) -> \(http.statusCode): \(body)\n".utf8))
        }

        struct NtfyMessage: Codable {
            let event: String
            let message: String?
        }
        for line in body.split(separator: "\n") {
            guard let msg = try? JSONDecoder().decode(NtfyMessage.self, from: Data(line.utf8)),
                  msg.event == "message", let text = msg.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { continue }
            let verdict: String?
            switch text.lowercased() {
            case "approve \(token)": verdict = "approved"
            case "deny \(token)": verdict = "denied"
            default: verdict = nil
            }
            if let verdict, AuditDB.shared.answerApproval(token: token, status: verdict, via: "ntfy") {
                AuditDB.shared.record(command: "approve answer", taskId: row.taskId,
                                      detail: "\(token): \(verdict) via ntfy")
                break
            }
        }
        return AuditDB.shared.approvalRows(token: token).first ?? row
    }
}

struct ApproveAnswer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "answer",
        abstract: "Answer an approval from this Mac (no phone round-trip). For the HUMAN — an agent answering its own request defeats the protocol and is visible in the audit log's caller column."
    )

    enum Verdict: String, ExpressibleByArgument { case approve, deny }

    @Argument(help: "Token from 'approve request'.")
    var token: String

    @Argument(help: "approve | deny")
    var verdict: Verdict

    func run() async throws {
        let status = verdict == .approve ? "approved" : "denied"
        guard AuditDB.shared.answerApproval(token: token, status: status, via: "cli") else {
            let existing = AuditDB.shared.approvalRows(token: token).first
            throw AppleTasksError.saveFailed(existing.map {
                "approval '\(token)' is already \($0.status)"
            } ?? "no approval with token '\(token)'")
        }
        AuditDB.shared.record(command: "approve answer", detail: "\(token): \(status) via cli")
        emit(ApprovalOut(AuditDB.shared.approvalRows(token: token).first!))
    }
}

struct ApproveList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List approval requests, newest first."
    )

    @Option(help: "Filter: pending | approved | denied | expired.")
    var status: String?

    @Option(help: "Max rows (default 50).")
    var limit: Int = 50

    func run() async throws {
        emit(AuditDB.shared.approvalRows(status: status, limit: limit).map { ApprovalOut($0) })
    }
}
