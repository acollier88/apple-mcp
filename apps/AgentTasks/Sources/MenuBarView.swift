import AppKit
import SwiftUI

// Menu bar for the ops app. Counts and rows come from apple-tasks
// (`dispatches`, `dispatch-status`, `approve list`). Pause and resume call
// `dispatch-pause` / `dispatch-resume`. Gatehouse is not shown: nothing in
// this repo speaks that protocol.

@MainActor
enum ConsoleWindow {
    private static var pending = false

    /// Notification actions have no SwiftUI openWindow environment. The menu
    /// bar label consumes `pending` and opens the WindowGroup if it has to.
    static func requestShow() {
        pending = true
        NotificationCenter.default.post(name: .agentTasksOpenConsole, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openIfNeeded(openNew: () -> Void) {
        guard pending else { return }
        pending = false
        show(openNew: openNew)
    }

    static func show(openNew: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: isConsole) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        openNew()
    }

    private static func isConsole(_ window: NSWindow) -> Bool {
        window.canBecomeMain
            && window.styleMask.contains(.titled)
            && window.title != ApprovalsWindow.title
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var ledger = LedgerWatcher.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if let badgeText {
                Text(badgeText)
            }
        }
        .accessibilityLabel(accessibilityText)
        .onAppear {
            ledger.start()
            ConsoleWindow.openIfNeeded { openWindow(id: "console") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentTasksOpenConsole)) { _ in
            ConsoleWindow.openIfNeeded { openWindow(id: "console") }
        }
    }

    private var symbol: String {
        if ledger.snapshot.pause.paused { return "pause.circle.fill" }
        if ledger.snapshot.running.isEmpty && !ledger.snapshot.approvals.isEmpty {
            return "hand.raised.fill"
        }
        return "bolt.horizontal"
    }

    /// Running count is the badge. When nothing is running, a pending
    /// approval count is the thing the human needs to see.
    private var badgeText: String? {
        let running = ledger.snapshot.running.count
        if running > 0 { return "\(running)" }
        if !ledger.snapshot.pause.paused && !ledger.snapshot.approvals.isEmpty {
            return "\(ledger.snapshot.approvals.count)"
        }
        return nil
    }

    private var accessibilityText: String {
        var parts = ["AgentTasks"]
        if ledger.snapshot.pause.paused { parts.append("paused") }
        let running = ledger.snapshot.running.count
        parts.append("\(running) running")
        let approvals = ledger.snapshot.approvals.count
        if approvals > 0 { parts.append("\(approvals) pending approvals") }
        return parts.joined(separator: ", ")
    }
}

struct MenuBarView: View {
    @ObservedObject private var ledger = LedgerWatcher.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(NotificationPrefs.failures) private var notifyFailures = true
    @AppStorage(NotificationPrefs.approvals) private var notifyApprovals = true
    @State private var decision: ApprovalDecision?
    /// First click on "Stop all" arms it; the second within 5s stops.
    @State private var stopArmed = false

    private let runningLimit = 4
    private let failureLimit = 3
    private let reviewLimit = 3
    private let approvalLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                statusBlock
                runningSection
                failureSection
                reviewSection
                approvalSection
                notifyBlock
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .onAppear { ledger.setMenuOpen(true) }
        .onDisappear { ledger.setMenuOpen(false) }
        .approvalAnswerAlert($decision, ledger: ledger)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.orange)
            Text("AgentTasks")
                .font(.headline)
            Spacer()
            Button("Console") {
                ConsoleWindow.show { openWindow(id: "console") }
            }
            .controlSize(.small)
            RefreshButton(isLoading: ledger.isRefreshing) {
                Task { await ledger.refresh(interactive: true) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PauseFormatting.statusLine(ledger.snapshot.pause))
                .font(.caption)
                .foregroundStyle(ledger.snapshot.pause.paused ? Color.orange : Color.secondary)
            if ledger.snapshot.pause.paused {
                Button("Resume") { Task { await ledger.resume() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(ledger.isActing)
                    .help("apple-tasks dispatch-resume")
            } else {
                HStack(spacing: 6) {
                    Button("Pause 1h") { Task { await ledger.pause(for: "1h") } }
                    Button("2h") { Task { await ledger.pause(for: "2h") } }
                    Button("Until 7am") { Task { await ledger.pauseUntilSevenAM() } }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(ledger.isActing)
                .help("apple-tasks dispatch-pause. Stops new claims; in-flight agents keep running.")
            }
            if !(ledger.snapshot.pause.reason ?? "").hasPrefix("stopped") {
                Button(stopArmed ? "Click again to stop everything" : "Stop all") {
                    if stopArmed {
                        stopArmed = false
                        Task { await ledger.stopAll() }
                    } else {
                        stopArmed = true
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            stopArmed = false
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
                .disabled(ledger.isActing)
                .help("apple-tasks stop --all. Pauses claiming, cancels every running agent, and turns off "
                    + "research, heals and playbooks until Resume.")
            }
            if let errorCaption = ledger.errorCaption {
                Text(errorCaption)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if let actionCaption = ledger.actionCaption {
                Text(actionCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var runningSection: some View {
        section(title: "Running", systemImage: "arrow.triangle.2.circlepath", count: ledger.snapshot.running.count) {
            if ledger.snapshot.running.isEmpty {
                emptyLine("Nothing running")
            } else {
                ForEach(Array(ledger.snapshot.running.prefix(runningLimit))) { row in
                    labeledRow(
                        primary: row.agent,
                        secondary: row.summary ?? row.command,
                        trailing: relativeTime(from: row.startedAt))
                }
                moreLine(total: ledger.snapshot.running.count, shown: runningLimit)
            }
        }
    }

    private var failureSection: some View {
        section(title: "Last failures", systemImage: "exclamationmark.circle", count: ledger.snapshot.failures.count) {
            if ledger.snapshot.failures.isEmpty {
                emptyLine("No recent failures")
            } else {
                ForEach(Array(ledger.snapshot.failures.prefix(failureLimit))) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(nonEmpty(row.summary) ?? nonEmpty(row.command) ?? row.taskId)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            StatusBadge(status: row.status)
                        }
                        HStack(spacing: 6) {
                            Text(row.agent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(relativeTime(from: row.finishedAt ?? row.startedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if let path = nonEmpty(row.runLogPath) {
                                Button("Log") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                moreLine(total: ledger.snapshot.failures.count, shown: failureLimit)
            }
        }
    }

    private var reviewSection: some View {
        section(title: "Pending review", systemImage: "eye", count: ledger.snapshot.reviews.count) {
            if ledger.snapshot.reviews.isEmpty {
                emptyLine("No branches waiting")
            } else {
                ForEach(Array(ledger.snapshot.reviews.prefix(reviewLimit))) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nonEmpty(row.summary) ?? row.taskId)
                            .font(.caption)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let branch = nonEmpty(row.branch) {
                                Text(branch)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let ahead = row.commitsAhead {
                                Text("\(ahead) ahead")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let worktree = nonEmpty(row.worktree) {
                                Button("Terminal") { openTerminal(worktree) }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                moreLine(total: ledger.snapshot.reviews.count, shown: reviewLimit)
            }
        }
    }

    private var approvalSection: some View {
        section(title: "Pending approvals", systemImage: "hand.raised", count: ledger.snapshot.approvals.count) {
            if ledger.snapshot.approvals.isEmpty {
                emptyLine("No pending approvals")
            } else {
                ForEach(Array(ledger.snapshot.approvals.prefix(approvalLimit))) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.question)
                            .font(.caption)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(item.token)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(relativeTime(from: item.requestedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Deny") {
                                decision = ApprovalDecision(token: item.token, question: item.question, approve: false)
                            }
                            .controlSize(.mini)
                            .disabled(ledger.answering.contains(item.token))
                            Button("Approve") {
                                decision = ApprovalDecision(token: item.token, question: item.question, approve: true)
                            }
                            .controlSize(.mini)
                            .disabled(ledger.answering.contains(item.token))
                        }
                    }
                }
                moreLine(total: ledger.snapshot.approvals.count, shown: approvalLimit)
            }
            Button("Open queue") { ApprovalsWindow.show() }
                .controlSize(.small)
                .help("Pending approvals from apple-tasks approve list")
        }
    }

    private var notifyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Toggle("Notify on failures", isOn: $notifyFailures)
            Toggle("Notify on approvals", isOn: $notifyApprovals)
            if ledger.notificationsDenied {
                Text("Notifications are blocked in System Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .toggleStyle(.checkbox)
        .padding(.top, 2)
    }

    private func section<Content: View>(
        title: String, systemImage: String, count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content()
        }
    }

    private func labeledRow(primary: String, secondary: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(primary)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(trailing)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func moreLine(total: Int, shown: Int) -> some View {
        if total > shown {
            Text("and \(total - shown) more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openTerminal(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }
}
