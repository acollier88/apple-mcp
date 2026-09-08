import EventKit
import Foundation

extension Dispatch {
    func plan(config: AgentsConfig, store: Store, requireAuto: Bool) async throws -> PlanResult {
        var reports: [DispatchReport] = []

        // Auto-triage (salvaged from PR #3, reworked): when agents.json has a
        // "triage" block, classify and route untagged inbox items before the
        // scan, so voice captures get tagged — and, if routed with [auto],
        // dispatched — in the same cycle. Same rule as everywhere else: the
        // classifier agent only judges; this CLI applies and audits every
        // mutation (see Triage.swift). Triage failure never blocks dispatch.
        if let t = config.triage {
            let inbox = t.inbox ?? "Reminders"
            let triageAgent = t.agent ?? "triage"
            if dryRun {
                reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                              agent: triageAgent, cwd: nil,
                                              action: "would triage untagged inbox items before dispatch",
                                              exitCode: nil, runLog: nil, worktree: nil))
            } else {
                do {
                    let result = try await Triage.triage(store: store, inbox: inbox,
                                                         agentTag: triageAgent, apply: true)
                    if result.untaggedCount > 0 {
                        let agentCount = result.actions.filter { $0.kind == "agent" }.count
                        let personal = result.actions.filter { $0.kind == "personal" }.count
                        reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                                      agent: triageAgent, cwd: nil,
                                                      action: "triaged \(result.actions.count): \(agentCount) agent, \(personal) personal",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                } catch {
                    reports.append(DispatchReport(taskId: "triage", title: "inbox '\(inbox)'",
                                                  agent: triageAgent, cwd: nil,
                                                  action: "triage failed: \(error.localizedDescription)",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
            }
        }

        let calendars = try listName.map { [try store.calendar(named: $0)] }
        let reminders = await store.reminders(in: calendars).filter { !$0.isCompleted }

        // Phase A (serial, EventKit + ledger): scan, claim, tag, prepare.
        // Emits plain-value RunSpecs; no EKReminder crosses into Phase B.
        var specs: [RunSpec] = []
        var specsPerAgent: [String: Int] = [:]
        let gates = GateContext() // probes cached across candidates this pass
        let budgetMode = AutoBudgetMode.parse(config.autoBudget)
        let bandwidth: BudgetBandwidth? = budgetMode == .off ? nil : BudgetBandwidth.load()

        // IDEAS #47: open-subtask counts per parent externalId, via ONE
        // private-helper call, computed lazily when the first candidate
        // reaches the dependency gate. nil helper/failure = no info, and
        // the gate simply doesn't fire.
        var openChildren: [String: Int]?
        func openSubtaskCount(_ externalId: String?) -> Int {
            guard let externalId else { return 0 }
            if openChildren == nil {
                var counts: [String: Int] = [:]
                let openIds = reminders.compactMap { $0.calendarItemExternalIdentifier }
                if let parents = NativeTags.parents(externalIds: openIds) {
                    for case let parent?? in parents.values { counts[parent, default: 0] += 1 }
                }
                openChildren = counts
            }
            return openChildren?[externalId] ?? 0
        }

        for reminder in reminders {
            let parsed = Tags.parse(reminder.title ?? "")
            let lowerTags = Set(parsed.tags.map { $0.lowercased() })
            let taskId = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier

            // Named lane tag pins that provider. `[auto]` with no matching
            // agent tag walks modelPrefs.auto (any available worker).
            let namedAgent = parsed.tags.first(where: {
                config.agents[$0.lowercased()] != nil
            })?.lowercased()
            let fromAutoPool = namedAgent == nil && lowerTags.contains("auto")
            if namedAgent == nil && !fromAutoPool { continue }
            if let onlyAgent {
                guard let namedAgent, namedAgent == onlyAgent.lowercased() else { continue }
            }
            if requireAuto && !lowerTags.contains("auto") { continue }
            let reportAgent = namedAgent ?? "auto"
            // Any Mac's claim blocks re-dispatch (IDEAS #13).
            if parsed.tags.contains(where: ClaimTags.isDispatched) {
                if dryRun {
                    let tag = parsed.tags.first(where: ClaimTags.isDispatched) ?? "dispatched"
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                  cwd: nil,
                                                  action: "skipped: already claimed [\(tag)] — complete the task or remove the claim tag to run the next occurrence",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
                continue
            }

            // Completion guard (P3): when claimGuard is "modified", skip a
            // task whose content fingerprint matches the last succeeded run
            // (agent exited 0 without completing, nothing has changed since).
            // Pre-v2 rows with no stored fingerprint never block. The
            // `[dispatched]` check above still wins first (another Mac, or a
            // run in flight). Default "running" leaves this gate off.
            if (config.claimGuard ?? "running") == "modified",
               let lastId = Self.unchangedSinceSuccess(
                   current: TaskFingerprint.of(reminder),
                   last: AuditDB.shared.latestSucceeded(taskId: taskId)) {
                if dryRun {
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                  cwd: nil,
                                                  action: "skipped: unchanged since succeeded #\(lastId) — edit the task or complete it to re-run",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
                continue
            }

            // Not due yet: stays queued until its due time. This is what
            // makes recurrence useful for agent work (IDEAS #36) — completing
            // a recurring task rolls it to the next occurrence, and without
            // this check the fresh occurrence would re-dispatch immediately
            // instead of at its scheduled time. Undated tasks dispatch as
            // always; a due date on an agent task means "run at", not "by".
            if let comps = reminder.dueDateComponents,
               let dueDate = Calendar.current.date(from: comps),
               dueDate > Date() {
                if dryRun {
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                  cwd: nil, action: "scheduled: not due until \(Dates.formatDue(reminder.dueDateComponents) ?? "?") — stays queued",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
                continue
            }

            var retryAttempt: Int?
            if let failedTag = parsed.tags.first(where: ClaimTags.isFailed) {
                // Another Mac's failure is its claim to retry (IDEAS #13) —
                // this ledger has no attempt history for it anyway.
                if !ClaimTags.isOwn(failedTag) {
                    if dryRun {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                      cwd: nil,
                                                      action: "skipped: claim [\(failedTag)] belongs to another Mac",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                    continue
                }
                let maxRetries = config.maxRetries ?? 0
                if maxRetries <= 0 {
                    if dryRun {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                      cwd: nil,
                                                      action: "skipped: [\(failedTag)] and maxRetries is 0",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                    continue
                }
                let (attempts, lastFailure) = AuditDB.shared.failedAttempts(taskId: taskId)
                if attempts > maxRetries {
                    if dryRun {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                      cwd: nil,
                                                      action: "skipped: \(attempts) failures exceeds maxRetries \(maxRetries)",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                    continue
                }
                let backoff = TimeInterval((config.retryBackoffMinutes ?? 30) * 60 * max(attempts, 1))
                if let lastFailure,
                   let lastDate = ISO8601DateFormatter().date(from: lastFailure),
                   Date().timeIntervalSince(lastDate) < backoff {
                    if dryRun {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                      cwd: nil,
                                                      action: "skipped: retry backoff until after \(lastFailure)",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                    continue
                }
                retryAttempt = attempts + 1
            }

            if AuditDB.shared.hasActiveDispatch(taskId: taskId) {
                if dryRun {
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                                  cwd: nil,
                                                  action: "skipped: ledger still has a running dispatch",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                }
                continue
            }

            // Subtask dependency gate (IDEAS #47): a parent stays queued
            // until every open subtask completes — subtasks dispatch on
            // their own agent tags like any other task.
            let subtasksOpen = openSubtaskCount(reminder.calendarItemExternalIdentifier)
            if subtasksOpen > 0 {
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: reportAgent,
                                              cwd: nil,
                                              action: "gated: \(subtasksOpen) open subtask\(subtasksOpen == 1 ? "" : "s") — stays queued",
                                              exitCode: nil, runLog: nil, worktree: nil))
                continue
            }

            let cwd = parsed.tags.lazy
                .compactMap { config.workdirs?[$0.lowercased()] }
                .first
                .map { NSString(string: $0).expandingTildeInPath }

            let pool: [String]
            if let namedAgent {
                pool = [namedAgent]
            } else {
                var walk = config.autoPool(preferWorktree: cwd != nil)
                if let bandwidth { walk = bandwidth.ordered(walk) }
                pool = walk
            }

            var skipNotes: [String] = []
            var agentTag: String?
            var agent: AgentsConfig.Agent?
            for tag in pool {
                guard let candidate = config.agents[tag] else { continue }
                if let reason = await Self.laneSkipReason(
                    tag: tag, agent: candidate, cwd: cwd,
                    specsPerAgent: specsPerAgent, gates: gates, config: config,
                    fromAutoPool: fromAutoPool, bandwidth: bandwidth, budgetMode: budgetMode
                ) {
                    skipNotes.append("\(tag): \(reason)")
                    continue
                }
                agentTag = tag
                agent = candidate
                break
            }
            guard let agentTag, let agent else {
                if let namedAgent, let note = skipNotes.first {
                    let reason = Self.stripLanePrefix(note)
                    if reason == "at cap" {
                        if dryRun {
                            reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: namedAgent,
                                                          cwd: cwd,
                                                          action: "skipped: agent '\(namedAgent)' is at maxConcurrent — stays queued",
                                                          exitCode: nil, runLog: nil, worktree: nil))
                        }
                        continue
                    }
                    if reason.hasPrefix("gated:") {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: namedAgent,
                                                      cwd: cwd, action: "\(reason) — stays queued",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    } else if reason == "no command or llm" {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: namedAgent,
                                                      cwd: nil,
                                                      action: "skipped: agent '\(namedAgent)' has neither \"command\" nor \"llm\" in agents.json",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    } else {
                        reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: namedAgent,
                                                      cwd: cwd, action: "queued: \(reason) — stays queued",
                                                      exitCode: nil, runLog: nil, worktree: nil))
                    }
                    continue
                }
                let why = skipNotes.isEmpty ? "auto pool empty" : skipNotes.joined(separator: "; ")
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: "auto",
                                              cwd: cwd,
                                              action: "queued: no available provider (\(why)) — stays queued",
                                              exitCode: nil, runLog: nil, worktree: nil))
                continue
            }

            var prompt = (agent.promptTemplate ?? AgentsConfig.defaultPromptTemplate)
                .replacingOccurrences(of: "{id}", with: taskId)
                .replacingOccurrences(of: "{list}", with: reminder.calendar?.title ?? "")
                .replacingOccurrences(of: "{title}", with: parsed.title)
                .replacingOccurrences(of: "{notes}", with: reminder.notes ?? "(none)")
                .replacingOccurrences(of: "{claimTag}", with: ClaimTags.dispatched)
            if agent.worktree == true, cwd != nil {
                prompt += "\nYou are in a dedicated git worktree on your own branch. " +
                    "Commit your work to the current branch; do not switch branches."
            }
            // Scratch fallback (IDEAS #54): no workdir tag is a valid state
            // (calendar debriefs, [research], notify-me tasks), not a failure.
            if cwd == nil {
                prompt += "\nNo repository is associated with this task; you are running in a " +
                    "throwaway scratch directory. Deliver results via apple-tasks — notes create, " +
                    "notify, or update \(taskId) --append-notes — not as files."
            }
            if lowerTags.contains("pr") {
                prompt += "\nThis task requires a Pull Request. When finished, push your branch to origin with 'git push -u origin HEAD' and open a PR with 'gh pr create' (title + a body describing the change and how you verified). Run these commands to associate it: apple-tasks update \(taskId) --url \"<PR url>\""
            }
            if lowerTags.contains("mail") {
                prompt += "\nThis task came from an email (From/Subject/Message-ID are in the task notes). Write your outcome as a reply DRAFT the human will review and send — never send mail yourself: apple-tasks mail draft --reply-to \"<Message-ID from the notes>\" --body-file <your report> (or --body \"...\")."
            }
            // [research] (IDEAS #53): one-shot deep-dive on a saved link or
            // topic; findings land in an Apple Note the human reads later.
            if lowerTags.contains("research") {
                let researchURL = reminder.url.map { "\nURL to research: \($0.absoluteString)" } ?? ""
                prompt += "\nThis is a RESEARCH task: investigate the URL/topic and report back — do not code.\(researchURL)\nRead pages with: apple-tasks web fetch \"<url>\" (repeat for obviously relevant linked pages; use your own web tools instead if you have them). Write your findings as an Apple Note: apple-tasks notes create --title \"Research: \(parsed.title)\" \"<findings as HTML>\" — lead with a 2-3 sentence answer, then supporting detail and source URLs. Then record a one-line conclusion on the task: apple-tasks update \(taskId) --append-notes \"<one-line conclusion + note title>\"."
            }
            // Attachments (IDEAS #46): hand the agent the real paths. Reading
            // file content needs Full Disk Access on the agent process; the
            // helper call is skipped on dry runs to keep them cheap.
            if !dryRun, let ext = reminder.calendarItemExternalIdentifier,
               let attachments = NativeTags.attachments(externalIds: [ext])?[ext],
               !attachments.isEmpty {
                prompt += "\nAttachments on this task (read file paths for context; if a file is unreadable your process lacks Full Disk Access — note that in your outcome):"
                for attachment in attachments.prefix(10) {
                    if let path = attachment.fileURL {
                        prompt += "\n- \(attachment.kind): \(path)"
                    } else if let url = attachment.url {
                        prompt += "\n- url: \(url)"
                    }
                }
            }
            guard let template = agent.commandTemplate(tag: agentTag) else {
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: nil,
                                              action: "skipped: agent '\(agentTag)' has neither \"command\" nor \"llm\" in agents.json",
                                              exitCode: nil, runLog: nil, worktree: nil))
                continue
            }
            let promptVia = agent.promptVia ?? .argv
            // For file mode the path isn't known until the ledger row exists;
            // substitute a placeholder now and patch it after the claim.
            let argv = Self.renderArgv(template, prompt: prompt, via: promptVia, promptFile: "{promptFile}")

            if dryRun {
                var action = retryAttempt.map { "would retry (attempt \($0))" } ?? "would dispatch"
                if fromAutoPool { action += " via \(agentTag) (auto pool)" }
                if cwd == nil { action += " (scratch — no workdir tag)" }
                let preview = prompt.count > 1600 ? String(prompt.prefix(1600)) + "…" : prompt
                reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                              cwd: cwd, action: action, exitCode: nil,
                                              runLog: nil, worktree: nil,
                                              command: template.joined(separator: " "),
                                              promptPreview: preview))
                continue
            }

            // Atomic claim first: the ledger row is the lock (single-statement
            // insert-if-absent), so two dispatchers can't both take the task.
            // Fail closed when the ledger is unavailable — never run unledgered.
            let ledgerId: Int64
            switch AuditDB.shared.claimDispatch(
                taskId: taskId, agent: agentTag, command: argv.joined(separator: " "), cwd: cwd) {
            case .held:
                continue
            case .unavailable:
                reports.append(DispatchReport(
                    taskId: taskId, title: parsed.title, agent: agentTag, cwd: cwd,
                    action: "skipped: ledger unavailable — refusing to dispatch unledgered",
                    exitCode: nil, runLog: nil, worktree: nil))
                continue
            case .claimed(let id):
                ledgerId = id
            }

            // Mark dispatched (visible everywhere via tag + native mirror);
            // a retry sheds its [failed] tag here. Written after the claim so
            // a crash between the two can't strand the tag with no ledger row.
            var tags = parsed.tags.filter { !ClaimTags.isFailed($0) }
            // Stamp the chosen lane so retries and the human-visible title
            // pin the provider that actually ran (leftmost matching tag wins).
            if fromAutoPool, !tags.contains(where: { $0.lowercased() == agentTag }) {
                tags.insert(agentTag, at: 0)
            }
            tags.append(ClaimTags.dispatched)
            reminder.title = Tags.compose(tags: tags, title: parsed.title)
            do {
                try store.save(reminder)
            } catch {
                AuditDB.shared.finishDispatch(id: ledgerId, status: "aborted", exitCode: -1)
                AuditDB.shared.record(command: "dispatch", taskId: taskId,
                                      list: reminder.calendar?.title,
                                      detail: "\(agentTag): \(parsed.title)",
                                      result: "error",
                                      error: "claim tag save failed: \(error)")
                reports.append(DispatchReport(
                    taskId: taskId, title: parsed.title, agent: agentTag, cwd: cwd,
                    action: "aborted: could not save claim tag: \(error.localizedDescription)",
                    exitCode: -1, runLog: nil, worktree: nil))
                continue
            }
            let shedFailed = parsed.tags.filter { ClaimTags.isFailed($0) }
            if !shedFailed.isEmpty {
                _ = NativeTags.remove(tags: shedFailed, externalId: reminder.calendarItemExternalIdentifier)
            }
            _ = NativeTags.mirror(tags: [ClaimTags.dispatched], externalId: reminder.calendarItemExternalIdentifier)
            AuditDB.shared.record(command: retryAttempt == nil ? "dispatch" : "dispatch-retry",
                                  taskId: taskId, list: reminder.calendar?.title,
                                  detail: "\(agentTag): \(parsed.title)"
                                      + (retryAttempt.map { " (attempt \($0))" } ?? ""))

            // Worktree isolation: agent output is a branch, never edits to the
            // main checkout. Refuse to run unisolated if creation fails.
            // With no workdir tag there is no repo to isolate; the task runs
            // in a throwaway per-dispatch scratch directory instead (IDEAS
            // #54) — worktree lanes included, since scratch IS the isolation.
            var runCwd = cwd
            var worktreePath: String?
            var branchName: String?
            if cwd == nil {
                let scratch = AgentsConfig.url.deletingLastPathComponent()
                    .appendingPathComponent("scratch/\(ledgerId)").path
                do {
                    try FileManager.default.createDirectory(
                        atPath: scratch, withIntermediateDirectories: true)
                } catch {
                    AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: -1)
                    await markFailed(store: store, taskId: taskId)
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                                  cwd: nil, action: "failed: could not create scratch dir \(scratch)",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                    continue
                }
                runCwd = scratch
            } else if agent.worktree == true, let repo = cwd {
                let wt = AgentsConfig.url.deletingLastPathComponent()
                    .appendingPathComponent("worktrees/\(ledgerId)").path
                let branch = "agent/\(agentTag)-\(ledgerId)"
                let gitCode = Self.runGit(["worktree", "add", "-b", branch, wt], repo: repo)
                guard gitCode == 0 else {
                    AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: gitCode)
                    await markFailed(store: store, taskId: taskId)
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                                  cwd: repo, action: "failed: git worktree add exited \(gitCode)",
                                                  exitCode: Int(gitCode), runLog: nil, worktree: nil))
                    continue
                }
                runCwd = wt
                worktreePath = wt
                branchName = branch
            }

            // Run log: everything the agent prints, kept per ledger row.
            let runsDir = AgentsConfig.url.deletingLastPathComponent().appendingPathComponent("runs")
            RunLogs.ensureDirectory(runsDir)
            let logURL = runsDir.appendingPathComponent("\(ledgerId).log")
            AuditDB.shared.setDispatchPaths(id: ledgerId, runLogPath: logURL.path, worktree: worktreePath)

            // Non-argv prompt delivery: persist the prompt beside the run log
            // (it is the file for `file` mode; a debugging copy for `stdin`).
            var finalArgv = argv
            var promptFile: String?
            if promptVia != .argv {
                let promptURL = runsDir.appendingPathComponent("\(ledgerId).prompt")
                do {
                    try RunLogs.writePrivate(Data(prompt.utf8), to: promptURL)
                } catch {
                    AuditDB.shared.finishDispatch(id: ledgerId, status: "failed", exitCode: -1)
                    await markFailed(store: store, taskId: taskId)
                    reports.append(DispatchReport(taskId: taskId, title: parsed.title, agent: agentTag,
                                                  cwd: cwd, action: "failed: could not write prompt file \(promptURL.path)",
                                                  exitCode: nil, runLog: nil, worktree: nil))
                    continue
                }
                promptFile = promptURL.path
                finalArgv = Self.renderArgv(template, prompt: prompt, via: promptVia, promptFile: promptURL.path)
            }

            specs.append(RunSpec(ledgerId: ledgerId, taskId: taskId, title: parsed.title,
                                 agentTag: agentTag, argv: finalArgv, repo: cwd, runCwd: runCwd,
                                 worktree: worktreePath, branch: branchName,
                                 timeoutMinutes: agent.timeoutMinutes, env: agent.env,
                                 logPath: logURL.path,
                                 promptVia: promptVia,
                                 stdinPrompt: promptVia == .stdin ? prompt : nil,
                                 promptFile: promptFile))
            specsPerAgent[agentTag, default: 0] += 1
        }

        return PlanResult(specs: specs, reports: reports, openReminderCount: reminders.count)
    }

    /// Ledger id of the last succeeded run that still matches `current`,
    /// or nil when the guard should not fire: no prior success, pre-v2 row
    /// without a fingerprint, the task has changed — or the last run did
    /// NOT end `open-claimed`. That last condition matters: an agent that
    /// ran `apple-tasks complete` on a recurring task rolled its due date
    /// during the run, so Phase C stored the post-roll fingerprint; when
    /// the next occurrence comes due nothing has changed since, and without
    /// this check the recurrence would be blocked forever. Only "agent
    /// exited 0 and walked away" is the idempotent case worth guarding.
    static func unchangedSinceSuccess(current fingerprint: String, last: AuditDB.DispatchRow?) -> Int? {
        guard let last, last.verification == "open-claimed",
              let stored = last.taskFingerprint, stored == fingerprint else { return nil }
        return last.id
    }

    /// nil = this lane can take the task this pass.
    private static func laneSkipReason(
        tag: String,
        agent: AgentsConfig.Agent,
        cwd: String?,
        specsPerAgent: [String: Int],
        gates: GateContext,
        config: AgentsConfig,
        fromAutoPool: Bool,
        bandwidth: BudgetBandwidth?,
        budgetMode: AutoBudgetMode
    ) async -> String? {
        guard agent.commandTemplate(tag: tag) != nil else {
            return "no command or llm"
        }
        if let cap = agent.maxConcurrent,
           AuditDB.shared.activeDispatchCount(agent: tag)
               + specsPerAgent[tag, default: 0] >= cap {
            return "at cap"
        }
        if let conditions = agent.conditions,
           let reason = await gates.gateReason(conditions, config: config) {
            return "gated: \(reason)"
        }
        if agent.worktree == true, cwd == nil {
            return "worktree needs a workdir tag"
        }
        if fromAutoPool, let bandwidth,
           let reason = bandwidth.skipReason(agentTag: tag, mode: budgetMode) {
            return reason
        }
        return nil
    }

    private static func stripLanePrefix(_ note: String) -> String {
        guard let idx = note.firstIndex(of: ":") else { return note }
        return String(note[note.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Substitute the prompt into an argv template according to `promptVia`.
    /// - argv: `{prompt}` → the prompt, inline.
    /// - stdin: entries that are exactly `{prompt}` are dropped (the prompt
    ///   is piped); any embedded `{prompt}` becomes "".
    /// - file: as stdin, plus `{promptFile}` → the prompt file path.
    static func renderArgv(_ template: [String], prompt: String,
                           via: AgentsConfig.PromptVia, promptFile: String) -> [String] {
        switch via {
        case .argv:
            return template.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
        case .stdin, .file:
            return template.compactMap { arg in
                if arg == "{prompt}" { return nil }
                return arg
                    .replacingOccurrences(of: "{prompt}", with: "")
                    .replacingOccurrences(of: "{promptFile}", with: promptFile)
            }
        }
    }
}
