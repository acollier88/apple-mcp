import AppKit
import SwiftUI

// MARK: - Models

struct QueueTask: Codable, Identifiable, Hashable {
    let id: String
    let externalId: String?
    let title: String
    let rawTitle: String
    let tags: [String]
    let list: String
    let notes: String?
    let due: String?
    let priority: String
    let completed: Bool
    let url: String?

    var stableId: String { externalId ?? id }

    var agentTag: String? {
        tags.first { t in
            let l = t.lowercased()
            return l != "auto"
                && !l.hasPrefix("dispatched")
                && !l.hasPrefix("failed")
                && !l.hasPrefix("personal")
                && !l.hasPrefix("mail")
                && !l.hasPrefix("pr")
        }
    }

    var isFailed: Bool {
        tags.contains { $0.lowercased() == "failed" || $0.lowercased().hasPrefix("failed:") }
    }

    var isDispatched: Bool {
        tags.contains { $0.lowercased() == "dispatched" || $0.lowercased().hasPrefix("dispatched:") }
    }
}

struct PlanList: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Queue tab

struct QueueTab: View {
    @Binding var refreshToken: Int

    @State private var tasks: [QueueTask] = []
    @State private var isLoading = false
    @State private var busyIds: Set<String> = []
    @State private var caption: String?
    @State private var showAdd = false
    @State private var filterAgent: String? = nil // nil = all agents
    @State private var showFailed = true

    private var agentFilters: [String] {
        Array(Set(tasks.compactMap(\.agentTag))).sorted()
    }

    private var filtered: [QueueTask] {
        tasks.filter { task in
            if let filterAgent, task.agentTag?.lowercased() != filterAgent.lowercased() {
                return false
            }
            if !showFailed && task.isFailed { return false }
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
        .sheet(isPresented: $showAdd) {
            AddTaskSheet {
                showAdd = false
                refreshToken += 1
                Task { await refresh() }
            } onCancel: {
                showAdd = false
            }
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
                Image(systemName: "tray.full")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Queue")
                    .font(.headline)
                Text("\(filtered.count) open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            Button {
                showAdd = true
            } label: {
                Label("Add Task", systemImage: "plus")
            }
            .help("Create a tagged task in Reminders")
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
                FilterChip(title: "All agents", selected: filterAgent == nil) {
                    filterAgent = nil
                }
                ForEach(agentFilters, id: \.self) { agent in
                    FilterChip(title: agent, selected: filterAgent == agent) {
                        filterAgent = agent
                    }
                }
                Divider().frame(height: 18)
                FilterChip(title: "Show failed", selected: showFailed) {
                    showFailed.toggle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        if tasks.isEmpty && !isLoading {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No open [auto] tasks")
                    .foregroundStyle(.secondary)
                Button("Add Task") { showAdd = true }
                    .buttonStyle(.link)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack {
                Spacer()
                Text("No tasks match filters")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { task in
                        QueueTaskRow(
                            task: task,
                            isBusy: busyIds.contains(task.stableId),
                            onComplete: { Task { await complete(task) } },
                            onFail: { Task { await fail(task) } }
                        )
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
        do {
            let json = try await Task.detached {
                try CLI.run(["list", "--tag", "auto", "--status", "open"], timeout: 45)
            }.value
            let decoded = try JSONDecoder().decode([QueueTask].self, from: Data(json.utf8))
            await MainActor.run {
                self.tasks = decoded
                self.isLoading = false
                self.caption = nil
            }
        } catch {
            await MainActor.run {
                self.tasks = []
                self.isLoading = false
                self.caption = "Queue failed: \(error.localizedDescription)"
            }
        }
    }

    private func complete(_ task: QueueTask) async {
        let key = task.stableId
        guard !busyIds.contains(key) else { return }
        busyIds.insert(key)
        caption = "Completing…"
        do {
            _ = try await Task.detached {
                try CLI.run(["complete", key], timeout: 30)
            }.value
            await MainActor.run {
                self.tasks.removeAll { $0.stableId == key }
                self.busyIds.remove(key)
                self.caption = "Completed: \(task.title)"
                self.refreshToken += 1
            }
        } catch {
            await MainActor.run {
                self.busyIds.remove(key)
                self.caption = "Complete failed: \(error.localizedDescription)"
            }
        }
    }

    private func fail(_ task: QueueTask) async {
        let key = task.stableId
        guard !busyIds.contains(key) else { return }
        busyIds.insert(key)
        caption = "Marking failed…"
        do {
            _ = try await Task.detached {
                var args = ["update", key, "--add-tag", "failed"]
                for tag in task.tags where tag.lowercased() == "dispatched"
                    || tag.lowercased().hasPrefix("dispatched:") {
                    args += ["--remove-tag", tag]
                }
                // Drop auto so dispatch won't keep picking it up until someone re-tags.
                if task.tags.contains(where: { $0.lowercased() == "auto" }) {
                    args += ["--remove-tag", "auto"]
                }
                args += ["--append-notes", "[ops] marked failed from AgentTasks"]
                return try CLI.run(args, timeout: 30)
            }.value
            await MainActor.run {
                self.busyIds.remove(key)
                self.caption = "Failed: \(task.title)"
                self.refreshToken += 1
            }
            await refresh()
        } catch {
            await MainActor.run {
                self.busyIds.remove(key)
                self.caption = "Fail failed: \(error.localizedDescription)"
            }
        }
    }
}

struct QueueTaskRow: View {
    let task: QueueTask
    let isBusy: Bool
    let onComplete: () -> Void
    let onFail: () -> Void
    @State private var isHovered = false
    @State private var confirmFail = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let agent = task.agentTag {
                            Text(agent)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(.orange)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if task.isDispatched {
                            Text("dispatched")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        if task.isFailed {
                            Text("failed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                        Text(task.list)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let due = task.due {
                        Text("due \(due)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        ForEach(task.tags.filter { $0.lowercased() != "auto" }.prefix(6), id: \.self) { tag in
                            Text("[\(tag)]")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Complete", action: onComplete)
                    .disabled(isBusy)
                Button("Fail", role: .destructive) {
                    confirmFail = true
                }
                .disabled(isBusy)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            Divider().opacity(0.4)
        }
        .background(
            task.isFailed
                ? (isHovered ? Color.red.opacity(0.06) : Color.red.opacity(0.03))
                : (isHovered ? Color.primary.opacity(0.02) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .alert("Mark failed?", isPresented: $confirmFail) {
            Button("Cancel", role: .cancel) {}
            Button("Fail", role: .destructive, action: onFail)
        } message: {
            Text("Removes [auto]/[dispatched], adds [failed], and appends a note. The task stays open for manual follow-up.")
        }
    }
}

// MARK: - Add Task

struct AddTaskSheet: View {
    let onCreated: () -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var listName = "Code Tasks"
    @State private var lists: [PlanList] = []
    @State private var agent = "cursor"
    @State private var repo = "apple-mcp"
    @State private var notes = ""
    @State private var priority = "none"
    @State private var includeAuto = true
    @State private var isSaving = false
    @State private var error: String?

    private let agents = ["cursor", "claude", "antigravity"]
    private let priorities = ["none", "low", "medium", "high"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Task")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
            }
            .padding(16)
            Divider()
            Form {
                TextField("Title", text: $title, prompt: Text("What should the agent do?"))
                Picker("List", selection: $listName) {
                    if lists.isEmpty {
                        Text(listName).tag(listName)
                    }
                    ForEach(lists) { list in
                        Text(list.name).tag(list.name)
                    }
                }
                Picker("Agent", selection: $agent) {
                    ForEach(agents, id: \.self) { Text($0).tag($0) }
                }
                TextField("Repo / workdir tag", text: $repo, prompt: Text("apple-mcp"))
                Toggle("Tag [auto] (dispatchable)", isOn: $includeAuto)
                Picker("Priority", selection: $priority) {
                    ForEach(priorities, id: \.self) { Text($0).tag($0) }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            Divider()
            HStack {
                Text(previewTitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Create") {
                    Task { await create() }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { Task { await loadLists() } }
    }

    private var previewTitle: String {
        var tags = [agent]
        let repoTag = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repoTag.isEmpty { tags.append(repoTag) }
        if includeAuto { tags.append("auto") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return tags.map { "[\($0)]" }.joined() + " " + (t.isEmpty ? "…" : t)
    }

    private func loadLists() async {
        do {
            let json = try await Task.detached {
                try CLI.run(["lists"], timeout: 30)
            }.value
            let decoded = try JSONDecoder().decode([PlanList].self, from: Data(json.utf8))
            await MainActor.run {
                self.lists = decoded
                if decoded.contains(where: { $0.name == listName }) == false,
                   let first = decoded.first {
                    self.listName = first.name
                }
            }
        } catch {
            // Keep default list name; create will surface errors.
        }
    }

    private func create() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        error = nil
        do {
            _ = try await Task.detached { [listName, agent, repo, notes, priority, includeAuto] in
                var args = ["add", "--list", listName, "--tag", agent]
                let repoTag = repo.trimmingCharacters(in: .whitespacesAndNewlines)
                if !repoTag.isEmpty { args += ["--tag", repoTag] }
                if includeAuto { args += ["--tag", "auto"] }
                if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args += ["--notes", notes]
                }
                if priority != "none" { args += ["--priority", priority] }
                args.append(trimmed)
                return try CLI.run(args, timeout: 30)
            }.value
            await MainActor.run {
                isSaving = false
                onCreated()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                self.error = error.localizedDescription
            }
        }
    }
}
