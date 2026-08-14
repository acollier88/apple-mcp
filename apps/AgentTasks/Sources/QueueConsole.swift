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
    let recurrence: String?

    /// Forces SwiftUI rows to rebuild when Reminders content changes (same id).
    var contentStamp: String {
        [rawTitle, notes ?? "", due ?? "", recurrence ?? "", priority, list, tags.joined(separator: ",")]
            .joined(separator: "\u{1e}")
    }

    /// Known agent lanes — prefer these over repo tags when labeling the row.
    static let knownAgents: Set<String> = [
        "cursor", "claude", "antigravity", "triage", "agy", "codex", "gemini", "byom",
        "hermes", "doctor", "auto",
    ]

    var stableId: String { externalId ?? id }

    var agentTag: String? {
        if let known = tags.first(where: { Self.knownAgents.contains($0.lowercased()) }) {
            return known
        }
        return tags.first { t in
            let l = t.lowercased()
            return l != "auto"
                && !l.hasPrefix("dispatched")
                && !l.hasPrefix("failed")
                && !l.hasPrefix("personal")
                && !l.hasPrefix("mail")
                && !l.hasPrefix("pr")
        }
    }

    /// True when no task tag maps to agents.json workdirs (dispatch worktree will fail).
    var needsWorkdir: Bool {
        WorkdirsStore.matchingTag(in: tags) == nil
    }

    /// Best tag to bind when the user picks a folder (orphan repo-like tag, if any).
    var orphanRepoTag: String? {
        tags.first { t in
            let l = t.lowercased()
            return l != "auto"
                && !l.hasPrefix("dispatched")
                && !l.hasPrefix("failed")
                && !l.hasPrefix("personal")
                && !l.hasPrefix("mail")
                && !l.hasPrefix("pr")
                && !Self.knownAgents.contains(l)
                && WorkdirsStore.matchingTag(in: [t]) == nil
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
    /// Increments every refresh request; in-flight results with an older epoch are dropped.
    @State private var refreshEpoch = 0
    @State private var busyIds: Set<String> = []
    @State private var caption: String?
    @State private var showAdd = false
    @State private var filterAgent: String? = nil // nil = all agents
    @State private var showFailed = true
    @State private var workdirs: [WorkdirsStore.Entry] = []

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
                    ForEach(filtered, id: \.stableId) { task in
                        QueueTaskRow(
                            task: task,
                            isBusy: busyIds.contains(task.stableId),
                            needsWorkdir: WorkdirsStore.matchingTag(in: task.tags, workdirs: workdirs) == nil,
                            onComplete: { Task { await complete(task) } },
                            onFail: { Task { await fail(task) } },
                            onSetFolder: { Task { await setFolder(for: task) } }
                        )
                        .id("\(task.stableId)|\(task.contentStamp)")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private func refresh() async {
        // Never drop a refresh while one is in flight — that left the Queue
        // stuck on stale rows after Reminders edits + a second Refresh click.
        refreshEpoch += 1
        let epoch = refreshEpoch
        isLoading = true
        workdirs = WorkdirsStore.load()
        do {
            let json = try await Task.detached {
                try CLI.run(["list", "--tag", "auto", "--status", "open"], timeout: 45)
            }.value
            let decoded = try JSONDecoder().decode([QueueTask].self, from: Data(json.utf8))
            await MainActor.run {
                guard epoch == refreshEpoch else { return }
                self.tasks = decoded
                self.isLoading = false
                self.caption = nil
            }
        } catch {
            await MainActor.run {
                guard epoch == refreshEpoch else { return }
                self.tasks = []
                self.isLoading = false
                self.caption = "Queue failed: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func setFolder(for task: QueueTask) async {
        let key = task.stableId
        guard !busyIds.contains(key) else { return }
        guard let url = WorkdirsStore.pickDirectory() else { return }
        busyIds.insert(key)
        caption = "Saving workdir…"
        do {
            let preferred = task.orphanRepoTag ?? WorkdirsStore.tagFromDirectoryName(url.path)
            let entry = try WorkdirsStore.upsert(tag: preferred, path: url.path)
            if !task.tags.contains(where: { $0.caseInsensitiveCompare(entry.tag) == .orderedSame }) {
                _ = try await Task.detached {
                    try CLI.run(["update", key, "--add-tag", entry.tag], timeout: 30)
                }.value
            }
            // Clear failed so a retry can pick it up once the workdir exists.
            if task.isFailed {
                var args = ["update", key, "--add-tag", "auto"]
                for tag in task.tags where tag.lowercased() == "failed"
                    || tag.lowercased().hasPrefix("failed:") {
                    args += ["--remove-tag", tag]
                }
                _ = try? await Task.detached {
                    try CLI.run(args, timeout: 30)
                }.value
            }
            workdirs = WorkdirsStore.load()
            busyIds.remove(key)
            caption = "Workdir [\(entry.tag)] → \(entry.path)"
            refreshToken += 1
            await refresh()
        } catch {
            busyIds.remove(key)
            caption = "Set folder failed: \(error.localizedDescription)"
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
    let needsWorkdir: Bool
    let onComplete: () -> Void
    let onFail: () -> Void
    let onSetFolder: () -> Void
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
                        if needsWorkdir {
                            Text("no workdir")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Text(task.list)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if needsWorkdir {
                        Text("Set a folder so dispatch can create a worktree (missing agents.json workdirs entry).")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        if let due = task.due {
                            Text("due \(due)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let recurrence = task.recurrence, !recurrence.isEmpty {
                            Text(recurrence)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let notes = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
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
                if needsWorkdir {
                    Button("Set Folder…", action: onSetFolder)
                        .disabled(isBusy)
                        .help("Pick a directory and register it in agents.json workdirs")
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

private let addTaskOtherRepo = "__other__"
private let addTaskNoRecipe = "__none__"

private enum RecurrencePreset: String, CaseIterable, Identifiable {
    case none = "None"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
    case custom = "Custom…"

    var id: String { rawValue }

    var rrule: String? {
        switch self {
        case .none: return nil
        case .daily: return "FREQ=DAILY"
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: return "FREQ=WEEKLY"
        case .custom: return nil // use customRecurrence field
        }
    }

    static func matching(rrule: String?) -> RecurrencePreset {
        guard let rrule, !rrule.isEmpty else { return .none }
        let upper = rrule.uppercased()
        for preset in Self.allCases where preset != .none && preset != .custom {
            if preset.rrule?.uppercased() == upper { return preset }
        }
        return .custom
    }
}

struct AddTaskSheet: View {
    let onCreated: () -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var listName = "Code Tasks"
    @State private var lists: [PlanList] = []
    @State private var agent = "cursor"
    @State private var workdirs: [WorkdirsStore.Entry] = []
    /// Selected workdir tag, or `addTaskOtherRepo` for a new folder.
    @State private var repoSelection = ""
    @State private var customTag = ""
    @State private var customPath = ""
    @State private var notes = ""
    @State private var priority = "none"
    @State private var includeAuto = true
    @State private var scheduleEnabled = false
    @State private var dueDate = Calendar.current.date(
        bySettingHour: 7, minute: 0, second: 0, of: Date()
    ) ?? Date()
    @State private var recurrencePreset: RecurrencePreset = .none
    @State private var customRecurrence = ""
    @State private var recipes: [RecipesStore.Recipe] = []
    @State private var recipeSelection = addTaskNoRecipe
    @State private var showSaveRecipe = false
    @State private var saveRecipeName = ""
    @State private var isSaving = false
    @State private var error: String?

    private let agents = ["auto", "cursor", "claude", "antigravity", "hermes"]
    private let priorities = ["none", "low", "medium", "high"]

    private var isOther: Bool { repoSelection == addTaskOtherRepo }

    private var resolvedRepoTag: String {
        if isOther {
            return WorkdirsStore.sanitizeTag(customTag)
        }
        return repoSelection
    }

    private var resolvedRepoPath: String? {
        if isOther {
            let p = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? nil : p
        }
        return workdirs.first(where: { $0.tag == repoSelection })?.path
    }

    private var resolvedRecurrence: String? {
        guard scheduleEnabled else { return nil }
        switch recurrencePreset {
        case .none: return nil
        case .custom:
            let r = customRecurrence.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? nil : r
        default:
            return recurrencePreset.rrule
        }
    }

    private var dueCLIString: String? {
        guard scheduleEnabled else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: dueDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Task")
                    .font(.headline)
                Spacer()
                recipeMenu
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
            }
            .padding(16)
            Divider()
            Form {
                if !recipes.isEmpty {
                    Picker("Recipe", selection: $recipeSelection) {
                        Text("Blank").tag(addTaskNoRecipe)
                        ForEach(recipes) { recipe in
                            Text(recipe.name).tag(recipe.id)
                        }
                    }
                    if let blurb = recipes.first(where: { $0.id == recipeSelection })?.description,
                       !blurb.isEmpty {
                        Text(blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                Picker("Repository", selection: $repoSelection) {
                    ForEach(workdirs) { entry in
                        Text("\(entry.tag) — \(shortPath(entry.path))").tag(entry.tag)
                    }
                    Text("Other folder…").tag(addTaskOtherRepo)
                }
                if isOther {
                    HStack {
                        TextField("Workdir tag", text: $customTag, prompt: Text("my-repo"))
                        Button("Choose Folder…") {
                            chooseFolder()
                        }
                    }
                    if !customPath.isEmpty {
                        Text(customPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Pick a directory to register in agents.json workdirs.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if let path = resolvedRepoPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle("Tag [auto] (dispatchable)", isOn: $includeAuto)
                Picker("Priority", selection: $priority) {
                    ForEach(priorities, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Schedule (due / repeat)", isOn: $scheduleEnabled)
                if scheduleEnabled {
                    DatePicker("First due", selection: $dueDate)
                    Picker("Repeat", selection: $recurrencePreset) {
                        ForEach(RecurrencePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    if recurrencePreset == .custom {
                        TextField("RRULE", text: $customRecurrence,
                                  prompt: Text("FREQ=WEEKLY;BYDAY=MO"))
                        Text("Subset: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY; INTERVAL; BYDAY; COUNT|UNTIL")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewTitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if scheduleEnabled, let due = dueCLIString {
                        Text(resolvedRecurrence.map { "due \(due) · \($0)" } ?? "due \(due)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Create") {
                    Task { await create() }
                }
                .disabled(!canCreate || isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 620)
        .onAppear {
            workdirs = WorkdirsStore.load()
            recipes = RecipesStore.load()
            if repoSelection.isEmpty {
                repoSelection = workdirs.first?.tag ?? addTaskOtherRepo
            }
            Task { await loadLists() }
        }
        .onChange(of: recipeSelection) { _, newId in
            guard newId != addTaskNoRecipe,
                  let recipe = recipes.first(where: { $0.id == newId }) else { return }
            applyRecipe(recipe)
        }
        .sheet(isPresented: $showSaveRecipe) {
            saveRecipeSheet
        }
    }

    private var recipeMenu: some View {
        Menu("Recipes") {
            Button("Import…") {
                if let recipe = RecipesStore.importFromPanel() {
                    recipes = RecipesStore.load()
                    recipeSelection = recipe.id
                    applyRecipe(recipe)
                }
            }
            Button("Export current…") {
                RecipesStore.exportToPanel(currentAsRecipe(name: title.isEmpty ? "untitled" : title))
            }
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Save current as recipe…") {
                saveRecipeName = title.trimmingCharacters(in: .whitespacesAndNewlines)
                showSaveRecipe = true
            }
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let recipe = recipes.first(where: { $0.id == recipeSelection }) {
                Divider()
                Button("Export “\(recipe.name)”…") {
                    RecipesStore.exportToPanel(recipe)
                }
            }
            Divider()
            Button("Reveal recipes folder") {
                RecipesStore.load()
                NSWorkspace.shared.open(RecipesStore.directory)
            }
        }
        .disabled(isSaving)
    }

    private var saveRecipeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save recipe")
                .font(.headline)
            TextField("Name", text: $saveRecipeName)
            HStack {
                Spacer()
                Button("Cancel") { showSaveRecipe = false }
                Button("Save") {
                    do {
                        let recipe = currentAsRecipe(name: saveRecipeName)
                        try RecipesStore.save(recipe)
                        recipes = RecipesStore.load()
                        recipeSelection = recipe.id
                        showSaveRecipe = false
                    } catch {
                        self.error = error.localizedDescription
                        showSaveRecipe = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveRecipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canCreate: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if scheduleEnabled, resolvedRecurrence != nil, dueCLIString == nil {
            return false
        }
        if isOther {
            return !resolvedRepoTag.isEmpty && resolvedRepoPath != nil
        }
        return !repoSelection.isEmpty && repoSelection != addTaskOtherRepo
    }

    private var previewTitle: String {
        var tags: [String] = []
        if agent.lowercased() != "auto" { tags.append(agent) }
        let repoTag = resolvedRepoTag
        if !repoTag.isEmpty { tags.append(repoTag) }
        if includeAuto { tags.append("auto") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return tags.map { "[\($0)]" }.joined() + " " + (t.isEmpty ? "…" : t)
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func applyRecipe(_ recipe: RecipesStore.Recipe) {
        title = recipe.title
        if let notes = recipe.notes { self.notes = notes }
        if let list = recipe.list, !list.isEmpty { listName = list }
        if let agent = recipe.agent, agents.contains(agent) || agent.lowercased() == "auto" {
            self.agent = agent
        }
        if let priority = recipe.priority, priorities.contains(priority) {
            self.priority = priority
        }
        includeAuto = recipe.includeAuto ?? true
        if let workdir = recipe.workdir, !workdir.isEmpty {
            if workdirs.contains(where: { $0.tag == workdir }) {
                repoSelection = workdir
            } else {
                // Keep current repo; recipe workdir may not be registered yet.
            }
        }
        if let dueTime = recipe.dueTime,
           let dueStr = RecipesStore.dueArgument(dueTime: dueTime, offsetDays: recipe.dueOffsetDays),
           let parsed = parseDue(dueStr) {
            scheduleEnabled = true
            dueDate = parsed
        } else if recipe.recurrence != nil {
            scheduleEnabled = true
        }
        if let rrule = recipe.recurrence, !rrule.isEmpty {
            scheduleEnabled = true
            recurrencePreset = RecurrencePreset.matching(rrule: rrule)
            if recurrencePreset == .custom {
                customRecurrence = rrule
            }
        } else {
            recurrencePreset = .none
            customRecurrence = ""
        }
    }

    private func currentAsRecipe(name: String) -> RecipesStore.Recipe {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        let dueTime = scheduleEnabled ? fmt.string(from: dueDate) : nil
        return RecipesStore.Recipe(
            id: RecipesStore.sanitizeId(name),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nil,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            list: listName,
            agent: agent,
            workdir: resolvedRepoTag.isEmpty ? nil : resolvedRepoTag,
            tags: nil,
            priority: priority == "none" ? nil : priority,
            includeAuto: includeAuto,
            dueTime: dueTime,
            dueOffsetDays: 0,
            recurrence: resolvedRecurrence
        )
    }

    private func parseDue(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.date(from: s)
    }

    @MainActor
    private func chooseFolder() {
        guard let url = WorkdirsStore.pickDirectory(startingAt: customPath.isEmpty ? nil : customPath) else {
            return
        }
        customPath = url.path
        if customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customTag = WorkdirsStore.tagFromDirectoryName(url.path)
        }
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
        guard canCreate else { return }
        isSaving = true
        error = nil
        do {
            let repoTag: String
            if isOther {
                guard let path = resolvedRepoPath else {
                    throw NSError(domain: "AgentTasks", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Choose a folder first"])
                }
                let entry = try WorkdirsStore.upsert(tag: resolvedRepoTag, path: path)
                repoTag = entry.tag
                await MainActor.run { self.workdirs = WorkdirsStore.load() }
            } else {
                repoTag = repoSelection
            }

            let due = dueCLIString
            let recurrence = resolvedRecurrence
            if recurrence != nil, due == nil {
                throw NSError(domain: "AgentTasks", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Recurrence requires a due date"])
            }

            struct AddOut: Decodable {
                let id: String
                let externalId: String?
                let nativeTags: Bool?
            }
            let addJSON = try await Task.detached {
                [listName, agent, notes, priority, includeAuto, repoTag, trimmed, due, recurrence] in
                var args = ["add", "--list", listName, "--tag", repoTag]
                if agent.lowercased() != "auto" { args += ["--tag", agent] }
                if includeAuto { args += ["--tag", "auto"] }
                if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args += ["--notes", notes]
                }
                if priority != "none" { args += ["--priority", priority] }
                if let due { args += ["--due", due] }
                if let recurrence { args += ["--recurrence", recurrence] }
                args.append(trimmed)
                return try CLI.run(args, timeout: 30)
            }.value
            let added = try JSONDecoder().decode(AddOut.self, from: Data(addJSON.utf8))
            // Title prefixes always land; native hashtags need the private helper
            // and can race ReminderKit right after create — remirror once if needed.
            if added.nativeTags != true {
                let key = added.externalId ?? added.id
                _ = try? await Task.detached {
                    try CLI.run(["remirror-tags", "--id", key], timeout: 45)
                }.value
            }
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
