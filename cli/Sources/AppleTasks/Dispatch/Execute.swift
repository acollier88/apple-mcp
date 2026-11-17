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
                group.addTask { await Self.execute(spec) }
                inFlight += 1
            }
            while let outcome = await group.next() {
                if let spec = pending.next() {
                    group.addTask { await Self.execute(spec) }
                }
                reports.append(await writeBack(outcome, store: store, config: config))
            }
        }
        return reports
    }

    /// Runs one agent process to completion. No EventKit — safe to run
    /// concurrently. The pid is written to the ledger right after spawn so
    /// reap/cancel can signal it; Phase C still records the outcome.
    private static func execute(_ spec: RunSpec) async -> RunOutcome {
        var argv = spec.argv
        var seat = AgentSeat.from(argv: argv)
        let captureCursor = AgentSeat.isCursorAgent(argv)
        if captureCursor {
            argv = AgentSeat.withStreamJSON(argv)
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

        // Cursor's stream-json has to be filtered into the run log. That is
        // the only path that reads a pipe; a grandchild holding the write end
        // used to block readDataToEndOfFile until reboot. AgentProcess.run
        // drains with a grace period and puts the agent in its own group.
        let pipeStdout = captureCursor && logHandle != nil
        let filter: CursorNDJSONFilter?
        if pipeStdout, let logHandle {
            filter = CursorNDJSONFilter(log: logHandle)
        } else {
            filter = nil
        }

        let result: AgentProcess.AgentRunResult
        do {
            result = try AgentProcess.run(
                executable: "/usr/bin/env",
                arguments: argv,
                environment: environment,
                directory: spec.runCwd,
                stdin: spec.promptVia == .stdin ? Data((spec.stdinPrompt ?? "").utf8) : nil,
                standardOutput: pipeStdout ? nil : logHandle,
                standardError: logHandle,
                captureStdout: pipeStdout,
                timeout: spec.timeoutMinutes.map { TimeInterval($0) * 60 },
                onSpawn: { pid in
                    // Leave pid set after exit (informational). The dispatcher
                    // pid lets reap tell a stuck pass from a dead one.
                    AuditDB.shared.setDispatchPid(
                        id: spec.ledgerId, pid: pid,
                        dispatcherPid: ProcessInfo.processInfo.processIdentifier)
                },
                onStdout: { filter?.ingest($0) })
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
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
