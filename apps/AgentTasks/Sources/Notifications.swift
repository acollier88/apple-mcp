import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    /// The menu bar label opens the ops console when it receives this.
    static let agentTasksOpenConsole = Notification.Name("AgentTasksOpenConsole")
}

enum NotificationPrefs {
    static let failures = "agentTasks.notifyFailures"
    static let approvals = "agentTasks.notifyApprovals"

    /// Missing key means on, matching the menu toggles' default.
    static func isOn(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// Remembers ledger ids so a refresh does not banner the same row again.
/// The first successful observation only records what is already there.
enum NotificationDedup {
    static let cap = 300

    static func fresh(current: [String], bootstrapped: Bool, seen: [String]) -> (ids: [String], seen: [String]) {
        let currentUnique = unique(current)
        if !bootstrapped {
            return ([], Array(currentUnique.prefix(cap)))
        }
        let seenSet = Set(seen)
        let freshIDs = currentUnique.filter { !seenSet.contains($0) }
        let merged = unique(freshIDs + currentUnique + seen)
        return (freshIDs, Array(merged.prefix(cap)))
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

enum LocalNotifications {
    static let failureCategory = "agenttasks.failure"
    static let approvalCategory = "agenttasks.approval"
    static let openLogAction = "OPEN_LOG"
    static let approveAction = "APPROVE"
    static let denyAction = "DENY"

    private static let failureReadyKey = "agentTasks.failuresBootstrapped"
    private static let approvalReadyKey = "agentTasks.approvalsBootstrapped"
    private static let failureSeenKey = "agentTasks.seenFailureIDs"
    private static let approvalSeenKey = "agentTasks.seenApprovalTokens"
    /// A wiped seen-set should not dump an old backlog of banners.
    private static let maxPostsPerRefresh = 5

    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        let openLog = UNNotificationAction(identifier: openLogAction, title: "Open Log", options: [.foreground])
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve", options: [.foreground])
        let deny = UNNotificationAction(
            identifier: denyAction, title: "Deny", options: [.destructive, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: failureCategory, actions: [openLog], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: []),
        ])
    }

    static func prepare() async {
        registerCategories()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func authorizationDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    /// `nil` skips that category (the fetch failed). An empty array is a real
    /// empty ledger and still seeds the seen-set.
    @MainActor
    static func deliver(failures: [DispatchLedgerRow]?, approvals: [PendingApproval]?) {
        if let failures {
            let fresh = note(
                current: failures.map { "\($0.id)" },
                readyKey: failureReadyKey, seenKey: failureSeenKey)
            if NotificationPrefs.isOn(NotificationPrefs.failures) {
                let byID = Dictionary(failures.map { ("\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
                for id in fresh.prefix(maxPostsPerRefresh) {
                    if let row = byID[id] { postFailure(row) }
                }
            }
        }
        if let approvals {
            let fresh = note(
                current: approvals.map(\.token),
                readyKey: approvalReadyKey, seenKey: approvalSeenKey)
            if NotificationPrefs.isOn(NotificationPrefs.approvals) {
                let byToken = Dictionary(approvals.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
                for token in fresh.prefix(maxPostsPerRefresh) {
                    if let row = byToken[token] { postApproval(row) }
                }
            }
        }
    }

    @MainActor
    static func handle(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let kind = info["kind"] as? String

        if let token = info["token"] as? String, !token.isEmpty,
           action == approveAction || action == denyAction {
            await LedgerWatcher.shared.answer(token: token, approve: action == approveAction)
            return
        }

        if action == openLogAction || (action == UNNotificationDefaultActionIdentifier && kind == "failure") {
            if let path = info["runLogPath"] as? String, !path.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                NSApp.activate(ignoringOtherApps: true)
            } else {
                ConsoleWindow.requestShow()
            }
            return
        }

        if kind == "approval" {
            ApprovalsWindow.show()
        }
    }

    private static func note(current: [String], readyKey: String, seenKey: String) -> [String] {
        let defaults = UserDefaults.standard
        let bootstrapped = defaults.object(forKey: readyKey) != nil
        let seen = defaults.stringArray(forKey: seenKey) ?? []
        let result = NotificationDedup.fresh(current: current, bootstrapped: bootstrapped, seen: seen)
        defaults.set(true, forKey: readyKey)
        defaults.set(result.seen, forKey: seenKey)
        return result.ids
    }

    private static func postFailure(_ row: DispatchLedgerRow) {
        let content = UNMutableNotificationContent()
        let title = nonEmpty(row.summary) ?? nonEmpty(row.command) ?? "Dispatch \(row.status)"
        content.title = clipped(title)
        content.body = "\(row.agent) · \(row.status)"
        content.sound = .default
        content.categoryIdentifier = failureCategory
        content.threadIdentifier = "agenttasks.failures"
        var info = ["kind": "failure", "id": "\(row.id)"]
        if let path = nonEmpty(row.runLogPath) { info["runLogPath"] = path }
        content.userInfo = info
        add(id: "failure-\(row.id)", content: content)
    }

    private static func postApproval(_ row: PendingApproval) {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed"
        content.body = clipped(row.question)
        content.sound = .default
        content.categoryIdentifier = approvalCategory
        content.threadIdentifier = "agenttasks.approvals"
        content.userInfo = ["kind": "approval", "token": row.token]
        add(id: "approval-\(row.token)", content: content)
    }

    private static func add(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clipped(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 140 { return collapsed }
        return String(collapsed.prefix(139)) + "…"
    }
}

final class AgentTasksDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--whereami` spins the main run loop from App.init; don't start
        // the menu-bar poller or a notification prompt on that path.
        guard !CommandLine.arguments.contains("--whereami") else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LocalNotifications.registerCategories(center: center)
        Task { @MainActor in
            LedgerWatcher.shared.start()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await LocalNotifications.handle(response)
            completionHandler()
        }
    }
}
