import AppKit
import SwiftUI

// MARK: - Models

struct AuditEvent: Codable, Identifiable {
    var id = UUID()
    let ts: String
    let caller: String
    let command: String
    let taskId: String?
    let list: String?
    let detail: String?
    let result: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ts, caller, command, taskId, list, detail, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ts = (try? container.decode(String.self, forKey: .ts)) ?? ""
        self.caller = (try? container.decode(String.self, forKey: .caller)) ?? "unknown"
        self.command = (try? container.decode(String.self, forKey: .command)) ?? ""
        self.taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        self.list = try container.decodeIfPresent(String.self, forKey: .list)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.result = (try? container.decode(String.self, forKey: .result)) ?? "ok"
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.id = UUID()
    }
}

struct DispatchLedgerRow: Codable, Identifiable {
    let id: Int
    let taskId: String
    let agent: String
    let command: String
    let cwd: String?
    let startedAt: String
    let finishedAt: String?
    let status: String
    let exitCode: Int?
    let runLogPath: String?
    let worktree: String?
    let summary: String?
    let verification: String?
    let reviewedAt: String?
    let taskFingerprint: String?
    let taskModifiedAt: String?
    let branch: String?
    let commitsAhead: Int?
    let commits: [String]?

    /// Small caption when verification is present and not `completed`.
    var verificationCaption: String? {
        guard let verification, verification != "completed" else { return nil }
        switch verification {
        case "open-claimed": return "agent exited without completing"
        case "open-untagged": return "task still open"
        default: return verification
        }
    }
}

struct DispatchDiscardResult: Codable {
    let id: Int
    let branch: String
    let worktreeRemoved: Bool
    let branchDeleted: Bool
}

struct DispatchReportRow: Codable {
    let taskId: String
    let title: String
    let agent: String
    let cwd: String?
    let action: String
    let exitCode: Int?
    let runLog: String?
    let worktree: String?
}

enum CallerFamily: String, CaseIterable, Identifiable {
    case all = "All"
    case agents = "Agents"
    case mcp = "MCP"
    case launchd = "Launchd"
    case app = "App"
    case other = "Other"

    var id: String { rawValue }

    func matches(_ caller: String) -> Bool {
        let c = caller.lowercased()
        switch self {
        case .all: return true
        case .agents: return c.contains("agent:")
        case .mcp: return c.contains("mcp")
        case .launchd: return c.contains("launchd")
        case .app: return c == "app" || c.hasPrefix("app ") || c.contains("agenttasks")
        case .other:
            return !c.contains("agent:") && !c.contains("mcp")
                && !c.contains("launchd") && c != "app" && !c.hasPrefix("app ")
                && !c.contains("agenttasks")
        }
    }
}

func relativeTime(from isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    var date = formatter.date(from: isoString)
    if date == nil {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = fractionalFormatter.date(from: isoString)
    }

    guard let date = date else { return isoString }
    let diff = Date().timeIntervalSince(date)
    if diff < 0 { return "now" }
    let seconds = Int(diff)
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

// MARK: - Root

struct ContentView: View {
    @State private var selectedTab = 0
    /// Bumped after dispatch / Reminders edits so tabs reload.
    @State private var refreshToken = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            QueueTab(refreshToken: $refreshToken)
                .tabItem { Label("Queue", systemImage: "tray.full") }
                .tag(0)
            ActivityTab(refreshToken: refreshToken)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(1)
            DispatchesTab(refreshToken: $refreshToken)
                .tabItem { Label("Dispatches", systemImage: "bolt.horizontal.circle") }
                .tag(2)
            PermissionsSettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .agentTasksEventKitChanged)) { _ in
            refreshToken += 1
        }
    }
}

// MARK: - Activity

struct ActivityTab: View {
    let refreshToken: Int

    @State private var events: [AuditEvent] = []
    @State private var isLoading = false
    @State private var isTriaging = false
    @State private var isMirroring = false
    @State private var statusCaption: String?
    @State private var commandFilter: String? = nil // nil = All
    @State private var callerFilter: CallerFamily = .all
    @State private var failuresOnly = false

    private var commandTypes: [String] {
        Array(Set(events.map(\.command).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [AuditEvent] {
        events.filter { event in
            if let commandFilter, event.command != commandFilter { return false }
            if !callerFilter.matches(event.caller) { return false }
            if failuresOnly && event.result == "ok" { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .onAppear { Task { await refresh() } }
        .onChange(of: refreshToken) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("AgentTasks")
                    .font(.headline)
                Text("Activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let statusCaption {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            Button {
                Task { await triage() }
            } label: {
                HStack(spacing: 5) {
                    if isTriaging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    Text("Triage Inbox")
                }
            }
            .disabled(isTriaging || isMirroring)
            .help("Classify and route untagged reminders in your inbox")

            Button {
                Task { await mirrorTags() }
            } label: {
                HStack(spacing: 5) {
                    if isMirroring {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tag")
                    }
                    Text("Mirror Tags")
                }
            }
            .disabled(isTriaging || isMirroring)
            .help("Re-apply [tag] title prefixes as native Reminders hashtags on open [auto] tasks")

            RefreshButton(isLoading: isLoading) {
                Task { await refresh() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All types", selected: commandFilter == nil) {
                    commandFilter = nil
                }
                ForEach(commandTypes, id: \.self) { cmd in
                    FilterChip(title: cmd, selected: commandFilter == cmd) {
                        commandFilter = cmd
                    }
                }

                Divider().frame(height: 18)

                ForEach(CallerFamily.allCases) { family in
                    FilterChip(title: family.rawValue, selected: callerFilter == family) {
                        callerFilter = family
                    }
                }

                Divider().frame(height: 18)

                FilterChip(title: "Failures", selected: failuresOnly) {
                    failuresOnly.toggle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty && !isLoading {
            emptyHero
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No events match filters")
                    .foregroundStyle(.secondary)
                Button("Clear filters") {
                    commandFilter = nil
                    callerFilter = .all
                    failuresOnly = false
                }
                .buttonStyle(.link)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { event in
                        EventRow(event: event)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 40))
            Text("AgentTasks")
                .font(.title2.bold())
            Text("Ops console for the agent queue. Activity shows the audit log; Dispatches shows ledger runs and lets you dispatch now. Siri/Shortcuts still work as before.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triage() async {
        guard !isTriaging else { return }
        isTriaging = true
        statusCaption = nil
        let summary: String = await Task.detached {
            do {
                let json = try CLI.run(["triage", "--apply"], timeout: 360)
                let data = Data(json.utf8)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let actions = obj["actions"] as? [[String: Any]] else { return "Triage done" }
                // Triage only classifies untagged inbox items; remirror so any
                // tags it just wrote (and other open [auto] work) get native hashtags.
                _ = try? CLI.run(["remirror-tags", "--tag", "auto", "--status", "open"], timeout: 120)
                if actions.isEmpty { return "Inbox clear — mirrored open [auto] tags" }
                let agents = actions.filter { ($0["kind"] as? String) == "agent" }.count
                let personal = actions.filter { ($0["kind"] as? String) == "personal" }.count
                return "Triaged \(actions.count): \(agents) agent, \(personal) personal · mirrored tags"
            } catch {
                return "Triage failed: \(error.localizedDescription)"
            }
        }.value
        await MainActor.run {
            self.statusCaption = summary
            self.isTriaging = false
        }
        await refresh()
    }

    private func mirrorTags() async {
        guard !isMirroring else { return }
        isMirroring = true
        statusCaption = nil
        let summary: String = await Task.detached {
            do {
                let json = try CLI.run(["remirror-tags", "--tag", "auto", "--status", "open"], timeout: 120)
                let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
                let ok = rows.filter { ($0["nativeTags"] as? Bool) == true }.count
                let failed = rows.filter { ($0["nativeTags"] as? Bool) == false }.count
                if rows.isEmpty { return "No open [auto] tasks to mirror" }
                if failed == 0 { return "Mirrored native tags on \(ok) task\(ok == 1 ? "" : "s")" }
                return "Mirrored \(ok), failed \(failed) (is apple-tasks-private next to the CLI?)"
            } catch {
                return "Mirror failed: \(error.localizedDescription)"
            }
        }.value
        await MainActor.run {
            self.statusCaption = summary
            self.isMirroring = false
        }
        await refresh()
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let jsonString = try await Task.detached {
                try CLI.run(["log", "--limit", "100"], timeout: 30)
            }.value
            let decoded = try JSONDecoder().decode([AuditEvent].self, from: Data(jsonString.utf8))
            await MainActor.run {
                self.events = decoded
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.events = []
                self.isLoading = false
                self.statusCaption = "Log failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Dispatches

struct DispatchesTab: View {
    @Binding var refreshToken: Int

    @State private var rows: [DispatchLedgerRow] = []
    @State private var isLoading = false
    @State private var isDispatching = false
    @State private var statusFilter: String? = nil // nil = All
    @State private var awaitingReview = false
    @State private var pendingReviewCount = 0
    @State private var caption: String?
    @State private var confirmDispatch = false
    @State private var confirmDiscard = false
    @State private var discardTarget: DispatchLedgerRow?

    private let statusOptions: [(label: String, value: String?)] = [
        ("All", nil),
        ("Running", "running"),
        ("Succeeded", "succeeded"),
        ("Failed", "failed"),
        ("Timeout", "timeout"),
    ]

    /// Combined filter key so switching All ↔ Awaiting review refreshes once.
    private var listQueryKey: String {
        awaitingReview ? "pending-review" : (statusFilter ?? "all")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            Divider()
            content
        }
        .alert("Dispatch now?", isPresented: $confirmDispatch) {
            Button("Cancel", role: .cancel) {}
            Button("Dispatch") {
                Task { await runDispatch(dryRun: false) }
            }
        } message: {
            Text("Runs apple-tasks dispatch for open [auto] tasks. Agents may start and consume their budgets. Prefer Dry Run first.")
        }
        .alert("Discard?", isPresented: $confirmDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                if let target = discardTarget {
                    Task { await discardDispatch(target) }
                }
            }
        } message: {
            Text("Delete branch \(discardTarget?.branch ?? "the branch") and its worktree? The commits are lost unless pushed.")
        }
        .onAppear { Task { await refresh() } }
        .onChange(of: listQueryKey) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Dispatches")
                    .font(.headline)
                if pendingReviewCount > 0 {
                    Text("\(pendingReviewCount) awaiting review")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .trailing)
            }

            if isDispatching {
                ProgressView().controlSize(.small)
            }

            Button("Dry Run") {
                Task { await runDispatch(dryRun: true) }
            }
            .disabled(isDispatching)
            .help("apple-tasks dispatch --dry-run")

            Button("Dispatch Now") {
                confirmDispatch = true
            }
            .disabled(isDispatching)
            .help("apple-tasks dispatch (same as LaunchAgent)")

            RefreshButton(isLoading: isLoading) {
                Task { await refresh() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            ForEach(statusOptions, id: \.label) { opt in
                FilterChip(title: opt.label, selected: !awaitingReview && statusFilter == opt.value) {
                    awaitingReview = false
                    statusFilter = opt.value
                }
            }
            Divider().frame(height: 18)
            FilterChip(title: "Awaiting review", selected: awaitingReview) {
                awaitingReview = true
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty && !isLoading {
            VStack(spacing: 8) {
                Spacer()
                Text(awaitingReview ? "No dispatches awaiting review" : "No dispatch ledger rows")
                    .foregroundStyle(.secondary)
                if !awaitingReview {
                    Text("Dry Run or wait for the LaunchAgent pass.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        DispatchRowView(row: row, reviewMode: awaitingReview) {
                            discardTarget = row
                            confirmDiscard = true
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        let review = awaitingReview
        let filter = statusFilter
        do {
            let jsonString = try await Task.detached {
                var args = ["dispatches", "--limit", "50"]
                if review {
                    args += ["--status", "pending-review"]
                } else if let filter {
                    args += ["--status", filter]
                }
                return try CLI.run(args, timeout: 30)
            }.value
            let decoded = try JSONDecoder().decode([DispatchLedgerRow].self, from: Data(jsonString.utf8))
            await MainActor.run {
                self.rows = decoded
                self.isLoading = false
                if review { self.pendingReviewCount = decoded.count }
            }
            if !review { await refreshPendingReviewCount() }
        } catch {
            await MainActor.run {
                self.rows = []
                self.isLoading = false
                self.caption = "Ledger failed: \(error.localizedDescription)"
            }
        }
    }

    /// Best-effort count for the header; ignore errors if the CLI lacks this filter yet.
    private func refreshPendingReviewCount() async {
        do {
            let jsonString = try await Task.detached {
                try CLI.run(["dispatches", "--status", "pending-review", "--limit", "50"], timeout: 30)
            }.value
            let decoded = try JSONDecoder().decode([DispatchLedgerRow].self, from: Data(jsonString.utf8))
            await MainActor.run { self.pendingReviewCount = decoded.count }
        } catch {
            // Leave the last known count; the Awaiting review chip surfaces a real error on click.
        }
    }

    private func discardDispatch(_ row: DispatchLedgerRow) async {
        do {
            let json = try await Task.detached {
                try CLI.run(["dispatch-discard", String(row.id)], timeout: 60)
            }.value
            let result = try? JSONDecoder().decode(DispatchDiscardResult.self, from: Data(json.utf8))
            await MainActor.run {
                if let result {
                    self.caption = "Discarded \(result.branch)"
                } else {
                    self.caption = "Discarded #\(row.id)"
                }
            }
            await refresh()
        } catch {
            await MainActor.run {
                self.caption = "Discard failed: \(error.localizedDescription)"
            }
        }
    }

    private func runDispatch(dryRun: Bool) async {
        guard !isDispatching else { return }
        isDispatching = true
        caption = dryRun ? "Dry-running…" : "Dispatching…"
        let summary: String = await Task.detached {
            do {
                var args = ["dispatch"]
                if dryRun { args.append("--dry-run") }
                // Real dispatch can run agents for a long time; cap so the UI recovers.
                let json = try CLI.run(args, timeout: dryRun ? 60 : 3600)
                let reports = (try? JSONDecoder().decode([DispatchReportRow].self, from: Data(json.utf8))) ?? []
                if reports.isEmpty {
                    return dryRun ? "Dry run: nothing to dispatch" : "Dispatch: nothing queued"
                }
                let would = reports.filter {
                    $0.action.hasPrefix("would ") || $0.action.hasPrefix("dispatched")
                }.count
                let gated = reports.filter { $0.action.hasPrefix("gated:") || $0.action.hasPrefix("skipped:") || $0.action.hasPrefix("scheduled:") }.count
                if dryRun {
                    return "Dry run: \(reports.count) row(s)"
                        + (would > 0 ? ", \(would) would run" : "")
                        + (gated > 0 ? ", \(gated) gated/skipped" : "")
                }
                let done = reports.filter {
                    ["succeeded", "failed", "timeout"].contains($0.action) || $0.action.hasPrefix("spawn")
                }.count
                return "Dispatch finished: \(reports.count) outcome(s)"
                    + (done > 0 ? ", \(done) run(s)" : "")
            } catch {
                return (dryRun ? "Dry run failed: " : "Dispatch failed: ") + error.localizedDescription
            }
        }.value
        await MainActor.run {
            self.caption = summary
            self.isDispatching = false
            self.refreshToken += 1
        }
        await refresh()
    }
}

struct DispatchRowView: View {
    let row: DispatchLedgerRow
    var reviewMode: Bool = false
    var onDiscard: (() -> Void)? = nil
    @State private var isHovered = false

    private var logAvailable: Bool {
        guard let path = row.runLogPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(relativeTime(from: row.startedAt))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .leading)

                Text("#\(row.id)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .leading)

                Text(row.agent)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.orange)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(Capsule())

                StatusBadge(status: row.status)

                if reviewMode {
                    Label("Review", systemImage: "eye")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.indigo)
                        .background(Color.indigo.opacity(0.1))
                        .clipShape(Capsule())
                        .labelStyle(.titleAndIcon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.summary ?? row.taskId)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let caption = row.verificationCaption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if reviewMode {
                        reviewMeta
                    }
                }

                Spacer()

                if reviewMode {
                    Button("Open in Terminal") {
                        openInTerminal()
                    }
                    .buttonStyle(.borderless)
                    .disabled(row.worktree?.isEmpty ?? true)
                    .help(row.worktree ?? "No worktree")
                }

                Button("Open Log") {
                    openLog()
                }
                .buttonStyle(.borderless)
                .disabled(!logAvailable)
                .help(row.runLogPath ?? "No run log")

                if reviewMode {
                    Button("Discard…", role: .destructive) {
                        onDiscard?()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)

            Divider().opacity(0.4)
        }
        .background(isHovered ? Color.primary.opacity(0.02) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .modifier(ReviewModeContextMenu(enabled: reviewMode) {
            Button {
                openInTerminal()
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }
            .disabled(row.worktree?.isEmpty ?? true)

            Button {
                openLog()
            } label: {
                Label("Open Log", systemImage: "doc.text")
            }
            .disabled(!logAvailable)

            Button("Discard…", role: .destructive) {
                onDiscard?()
            }
        })
    }

    @ViewBuilder
    private var reviewMeta: some View {
        HStack(spacing: 8) {
            if let branch = row.branch, !branch.isEmpty {
                Text(branch)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let ahead = row.commitsAhead {
                Text("\(ahead) commit\(ahead == 1 ? "" : "s") ahead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let first = row.commits?.first, !first.isEmpty {
            Text(first)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func openLog() {
        if let path = row.runLogPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func openInTerminal() {
        guard let worktree = row.worktree, !worktree.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", worktree]
        try? process.run()
    }
}

/// Attaches a context menu only in review mode so default rows don't get an empty menu.
private struct ReviewModeContextMenu<Menu: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder var menu: () -> Menu

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu(menuItems: menu)
        } else {
            content
        }
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        let colors = colors(for: status)
        Text(status)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(colors.text)
            .background(colors.bg)
            .cornerRadius(4)
    }

    private func colors(for status: String) -> (text: Color, bg: Color) {
        switch status {
        case "succeeded": return (.green, Color.green.opacity(0.12))
        case "running": return (.blue, Color.blue.opacity(0.12))
        case "failed", "timeout", "aborted": return (.red, Color.red.opacity(0.12))
        default: return (.secondary, Color.secondary.opacity(0.12))
        }
    }
}

// MARK: - Shared chrome

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RefreshButton: View {
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.blue : Color.secondary)
                .rotationEffect(.degrees(isLoading ? 360 : 0))
                .animation(isLoading ? Animation.linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: isLoading)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .help("Refresh")
    }
}

struct EventRow: View {
    let event: AuditEvent
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(relativeTime(from: event.ts))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .leading)

                BadgeView(caller: event.caller)

                Text(event.command)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(event.result == "ok" ? Color.primary : Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(event.result == "ok" ? Color.primary.opacity(0.05) : Color.red.opacity(0.1))
                    .cornerRadius(4)

                Text(event.detail ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(event.result == "ok" ? Color.primary : Color.red)

                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)

            Divider().opacity(0.4)
        }
        .background(
            event.result == "ok"
                ? (isHovered ? Color.primary.opacity(0.02) : Color.clear)
                : (isHovered ? Color.red.opacity(0.06) : Color.red.opacity(0.03))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

struct BadgeView: View {
    let caller: String

    var body: some View {
        let badge = callerBadge(for: caller)
        let colors = badgeColors(for: badge)

        Text(badge)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(colors.text)
            .background(colors.bg)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(colors.border, lineWidth: 1)
            )
    }

    private func callerBadge(for caller: String) -> String {
        let c = caller.lowercased()
        if let range = c.range(of: "agent:") {
            let after = String(c[range.upperBound...])
            let tag = after.split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_"
            }).first.map(String.init) ?? String(after.prefix(24))
            return "agent:\(tag)"
        }
        if c.contains("launchd") { return "launchd" }
        if c.contains("mcp") { return "mcp" }
        if c.contains("agenttasks") || c == "app" || c.hasPrefix("app ") { return "app" }
        if c.contains("zsh") { return "zsh" }
        if c.contains("bash") { return "bash" }
        return caller
    }

    private func badgeColors(for badge: String) -> (text: Color, bg: Color, border: Color) {
        if badge == "agent:cursor" {
            return (Color.purple, Color.purple.opacity(0.12), Color.purple.opacity(0.35))
        }
        if badge == "launchd" {
            return (Color.teal, Color.teal.opacity(0.12), Color.teal.opacity(0.35))
        }
        if badge.starts(with: "agent:") {
            return (Color.orange, Color.orange.opacity(0.1), Color.orange.opacity(0.3))
        }
        switch badge {
        case "mcp":
            return (Color.indigo, Color.indigo.opacity(0.1), Color.indigo.opacity(0.3))
        case "app":
            return (Color.blue, Color.blue.opacity(0.1), Color.blue.opacity(0.3))
        default:
            return (Color.secondary, Color.secondary.opacity(0.1), Color.secondary.opacity(0.3))
        }
    }
}
