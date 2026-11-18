import AppKit
import SwiftUI

// Pending apple-tasks approvals (`approve list` / `approve answer`).
// Gatehouse is intentionally absent: this repo has no gatehouse socket or
// config, and its approval page is not built.

struct ApprovalDecision: Identifiable, Equatable {
    let token: String
    let question: String
    let approve: Bool

    var id: String { "\(token)#\(approve ? "approve" : "deny")" }
    var title: String { approve ? "Approve this request?" : "Deny this request?" }
}

@MainActor
enum ApprovalsWindow {
    static let title = "Pending Approvals"
    private static var controller: NSWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = controller?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: ApprovalsQueueView())
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.setContentSize(NSSize(width: 520, height: 560))
        window.minSize = NSSize(width: 420, height: 320)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
    }
}

struct ApprovalsQueueView: View {
    @ObservedObject private var ledger = LedgerWatcher.shared
    @State private var decision: ApprovalDecision?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .approvalAnswerAlert($decision, ledger: ledger)
        .onAppear {
            ledger.start()
            Task { await ledger.refresh(interactive: true) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("Pending approvals")
                .font(.headline)
            if !ledger.snapshot.approvals.isEmpty {
                Text("\(ledger.snapshot.approvals.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionCaption = ledger.actionCaption {
                Text(actionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            RefreshButton(isLoading: ledger.isRefreshing) {
                Task { await ledger.refresh(interactive: true) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorCaption = ledger.errorCaption, ledger.snapshot.approvals.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(errorCaption)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer()
            }
            .padding(24)
        } else if ledger.snapshot.approvals.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No pending approvals")
                    .foregroundStyle(.secondary)
                Text("Requests from apple-tasks approve list show up here. Approve and Deny call approve answer on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Spacer()
            }
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ledger.snapshot.approvals) { item in
                        approvalRow(item)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private func approvalRow(_ item: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.question)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(item.token)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(relativeTime(from: item.requestedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let taskId = item.taskId, !taskId.isEmpty {
                    Text(String(taskId.prefix(8)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Deny") { decision = ApprovalDecision(token: item.token, question: item.question, approve: false) }
                    .disabled(ledger.answering.contains(item.token))
                    .help("apple-tasks approve answer \(item.token) deny")
                Button("Approve") { decision = ApprovalDecision(token: item.token, question: item.question, approve: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(ledger.answering.contains(item.token))
                    .help("apple-tasks approve answer \(item.token) approve")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

private struct ApprovalAnswerAlert: ViewModifier {
    @Binding var decision: ApprovalDecision?
    @ObservedObject var ledger: LedgerWatcher

    func body(content: Content) -> some View {
        content.alert(
            decision?.title ?? "Approval",
            isPresented: Binding(
                get: { decision != nil },
                set: { if !$0 { decision = nil } }
            ),
            presenting: decision
        ) { pending in
            if pending.approve {
                Button("Approve") { confirm(pending) }
            } else {
                Button("Deny", role: .destructive) { confirm(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.question)
        }
    }

    private func confirm(_ pending: ApprovalDecision) {
        Task { await ledger.answer(token: pending.token, approve: pending.approve) }
    }
}

extension View {
    func approvalAnswerAlert(_ decision: Binding<ApprovalDecision?>, ledger: LedgerWatcher) -> some View {
        modifier(ApprovalAnswerAlert(decision: decision, ledger: ledger))
    }
}
