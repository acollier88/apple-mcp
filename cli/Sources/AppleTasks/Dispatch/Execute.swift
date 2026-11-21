import EventKit
import Foundation

extension Dispatch {
    func executeAll(_ specs: [RunSpec], config: AgentsConfig, store: Store) async -> [DispatchReport] {
        var reports: [DispatchReport] = []
        // Phase B (concurrent, EventKit-free): run the agents, capped. The
        // collection loop below runs serially on this task, so recording and
        // write-backs (Phase C) happen per-outcome, as each agent finishes.
        let cap = max(config.maxConcurrent ?? 1, 1)
        await withTaskGroup(of: RunOutcome.self) { group in
            var pending = specs.makeIterator()
            var inFlight = 0
            while inFlight < cap, let spec = pending.next() {
                if let failure = await beginClaim(spec, store: store) {
                    reports.append(failure)
                } else {
                    group.addTask { await Self.execute(spec) }
                    inFlight += 1
                }
            }
            while let outcome = await group.next() {
                while let spec = pending.next() {
                    if let failure = await beginClaim(spec, store: store) {
                        reports.append(failure)
                    } else {
                        group.addTask { await Self.execute(spec) }
                        break
                    }
                }
                reports.append(await writeBack(outcome, store: store, config: config))
            }
        }
        return reports
    }

    /// Stamp `[dispatched]` at the moment this spec is about to run. Nil
    /// means the tag is on the reminder. A report means the save failed:
    /// the ledger row is closed so it does not stay `running`, and the
    /// agent is not started.
    private func beginClaim(_ spec: RunSpec, store: Store) async -> DispatchReport? {
        do {
            let current = try await store.reminder(id: spec.taskId)
            var (tags, title) = Tags.parse(current.title ?? "")
            let shedFailed = tags.filter { ClaimTags.isFailed($0) && ClaimTags.isOwn($0) }
            tags.removeAll { ClaimTags.isFailed($0) && ClaimTags.isOwn($0) }
            if spec.stampLane, !tags.contains(where: { $0.lowercased() == spec.agentTag }) {
                tags.insert(spec.agentTag, at: 0)
            }
            if !tags.contains(where: { ClaimTags.isDispatched($0) && ClaimTags.isOwn($0) }) {
                tags.append(ClaimTags.dispatched)
            }
            current.title = Tags.compose(tags: tags, title: title)
            try store.save(current)
            if !shedFailed.isEmpty {
                _ = NativeTags.remove(tags: shedFailed, externalId: current.calendarItemExternalIdentifier)
            }
            _ = NativeTags.mirror(tags: [ClaimTags.dispatched], externalId: current.calendarItemExternalIdentifier)
            return nil
        } catch {
            let message = "claim tag save failed: \(error.localizedDescription)"
            Self.passLog("\(message) ledger #\(spec.ledgerId)")
            _ = AuditDB.shared.finishDispatch(id: spec.ledgerId, status: "aborted", exitCode: -1, summary: message)
            // Planning already created the worktree and its branch; no agent
            // ran, so both are empty. Remove them now rather than leave them.
            if let wt = spec.worktree, let repo = spec.repo {
                if Self.runGit(["worktree", "remove", "--force", wt], repo: repo) == 0 {
                    if let branch = spec.branch {
                        _ = Self.runGit(["branch", "-D", branch], repo: repo)
                    }
                    _ = AuditDB.shared.clearWorktree(id: spec.ledgerId)
                }
            }
            return DispatchReport(
                taskId: spec.taskId, title: spec.title, agent: spec.agentTag, cwd: spec.runCwd,
                action: "aborted: \(message)",
                exitCode: -1, runLog: spec.logPath, worktree: spec.worktree)
        }
    }

    /// Runs one agent process to completion. No EventKit — safe to run
    /// concurrently. The pid is written to the ledger right after spawn so
    /// reap/cancel can signal it; Phase C still records the outcome.
    private static func execute(_ spec: RunSpec) async -> RunOutcome {
        var argv = spec.argv
        let lane = Self.laneArgv(argv)
        var seat = AgentSeat.from(argv: lane)
        let captureCursor = AgentSeat.isCursorAgent(lane)
        if captureCursor {
            argv = Self.mapLaneArgv(argv, AgentSeat.withStreamJSON)
        }

        let parentEnv = ProcessInfo.processInfo.environment
        // Env reporting lists dropped NAMES only, never values.
        var envLine = "# env: \(spec.envPolicy.mode.rawValue)"
        if spec.envPolicy.mode != .inherit {
            let dropped = AgentEnv.droppedNames(parent: parentEnv, policy: spec.envPolicy)
            envLine += " (dropped \(dropped.count)\(dropped.isEmpty ? "" : ": " + dropped.joined(separator: ", ")))"
        }
        let logHandle = RunLogs.create(at: spec.logPath)
        logHandle?.write(Data("""
        # dispatch #\(spec.ledgerId) \(ISO8601DateFormatter().string(from: Date()))
        # task \(spec.taskId): \(spec.title)
        \(seat.logLine)
        \(envLine)
        # \(spec.displayCommand)\n\n
        """.utf8))
        defer { try? logHandle?.close() }

        // GUI apps and launchd do not source ~/.zshrc — bare `agent` / `claude`
        // live in ~/.local/bin or Homebrew. The PATH rewrite prepends those so
        // /usr/bin/env finds them.
        let environment = AgentEnv.build(
            parent: parentEnv, policy: spec.envPolicy,
            caller: "agent:\(spec.agentTag)",
            searchPath: { Self.agentSearchPath(existing: $0) })

        // Always pipes. A log-file handle as stdout/stderr makes the Cursor
        // CLI abort under a sandbox, and readDataToEndOfFile after exit hangs
        // when a grandchild keeps the pipe open. AgentProcess.run puts the
        // agent in its own process group, copies both pipes into the run log,
        // and bounds the post-exit drain.
        let outputLock = NSLock()
        let filter: CursorNDJSONFilter? = (captureCursor && logHandle != nil)
            ? CursorNDJSONFilter(log: logHandle!, writeLock: outputLock) : nil
        func writeLog(_ data: Data) {
            guard let logHandle, !data.isEmpty else { return }
            outputLock.lock()
            logHandle.write(data)
            outputLock.unlock()
        }

        let result: AgentProcess.AgentRunResult
        do {
            // AgentProcess.run polls and sleeps until the agent exits (up to
            // the lane timeout). Run it on its own thread so a long agent does
            // not hold one of Swift concurrency's few cooperative threads.
            result = try await Self.onDedicatedThread { try AgentProcess.run(
                executable: "/usr/bin/env",
                arguments: argv,
                environment: environment,
                directory: spec.runCwd,
                stdin: spec.promptVia == .stdin ? Data((spec.stdinPrompt ?? "").utf8) : nil,
                captureStdout: logHandle != nil,
                captureStderr: logHandle != nil,
                timeout: spec.timeoutSeconds.map { TimeInterval($0) }
                    ?? spec.timeoutMinutes.map { TimeInterval($0) * 60 },
                onSpawn: { pid in
                    // Leave pid set after exit (informational). The dispatcher
                    // pid lets reap tell a stuck pass from a dead one.
                    AuditDB.shared.setDispatchPid(
                        id: spec.ledgerId, pid: pid,
                        dispatcherPid: ProcessInfo.processInfo.processIdentifier)
                },
                onStdout: { chunk in
                    if let filter {
                        filter.ingest(chunk)
                    } else {
                        writeLog(chunk)
                    }
                },
                onStderr: { writeLog($0) }) }
        } catch {
            return RunOutcome(spec: spec, status: "spawn failed", exitCode: nil,
                              spawnError: error.localizedDescription, seat: seat)
        }
        filter?.flush()
        if let resolved = filter?.resolvedModel { seat.resolved = resolved }
        if let sessionId = filter?.sessionId { seat.sessionId = sessionId }
        let status = result.timedOut ? "timeout" : (result.status == 0 ? "succeeded" : "failed")
        return RunOutcome(spec: spec, status: status, exitCode: result.status, spawnError: nil, seat: seat)
    }

    /// Run blocking `work` on a fresh thread and resume when it returns.
    static func onDedicatedThread<T>(_ work: @escaping () throws -> T) async throws -> T {
        let box = ThreadWorkBox(work)
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning: try box.work()) }
                catch { continuation.resume(throwing: error) }
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    static func gitOutput(_ args: [String], repo: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runGit(_ args: [String], repo: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        // Keep git chatter out of the command's JSON stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// Carries a non-Sendable closure to the thread that runs it once.
private final class ThreadWorkBox<T>: @unchecked Sendable {
    let work: () throws -> T
    init(_ work: @escaping () throws -> T) { self.work = work }
}
