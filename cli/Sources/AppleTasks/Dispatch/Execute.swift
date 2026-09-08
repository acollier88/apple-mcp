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

    /// Runs one agent process to completion. No EventKit, no AuditDB — safe
    /// to run concurrently; all recording happens serially in Phase C.
    private static func execute(_ spec: RunSpec) async -> RunOutcome {
        var argv = spec.argv
        var seat = AgentSeat.from(argv: argv)
        let captureCursor = AgentSeat.isCursorAgent(argv)
        if captureCursor {
            argv = AgentSeat.withStreamJSON(argv)
        }

        FileManager.default.createFile(atPath: spec.logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: spec.logPath)
        logHandle?.write(Data("""
        # dispatch #\(spec.ledgerId) \(ISO8601DateFormatter().string(from: Date()))
        # task \(spec.taskId): \(spec.title)
        \(seat.logLine)
        # \(spec.argv.joined(separator: " "))\n\n
        """.utf8))
        defer { try? logHandle?.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let runCwd = spec.runCwd { process.currentDirectoryURL = URL(fileURLWithPath: runCwd) }
        var env = ProcessInfo.processInfo.environment
        for (name, value) in spec.env ?? [:] { env[name] = value }
        env["APPLE_TASKS_CALLER"] = "agent:\(spec.agentTag)"
        // GUI apps and launchd do not source ~/.zshrc — bare `agent` / `claude`
        // live in ~/.local/bin or Homebrew. Prepend those so /usr/bin/env finds them.
        env["PATH"] = Self.agentSearchPath(existing: env["PATH"])
        process.environment = env

        let stdoutPipe: Pipe? = captureCursor ? Pipe() : nil
        let filter: CursorNDJSONFilter?
        if captureCursor, let logHandle, let stdoutPipe {
            filter = CursorNDJSONFilter(log: logHandle)
            process.standardOutput = stdoutPipe
            process.standardError = logHandle
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                filter?.ingest(handle.availableData)
            }
        } else {
            filter = nil
            if let logHandle {
                process.standardOutput = logHandle
                process.standardError = logHandle
            }
        }

        do {
            try process.run()
        } catch {
            return RunOutcome(spec: spec, status: "spawn failed", exitCode: nil,
                              spawnError: error.localizedDescription, seat: seat)
        }
        var timedOut = false
        if let minutes = spec.timeoutMinutes {
            let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                for _ in 0..<5 where process.isRunning {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()
        if let stdoutPipe {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            filter?.ingest(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            filter?.flush()
        }
        if let resolved = filter?.resolvedModel { seat.resolved = resolved }
        if let sessionId = filter?.sessionId { seat.sessionId = sessionId }
        let code = process.terminationStatus
        let status = timedOut ? "timeout" : (code == 0 ? "succeeded" : "failed")
        return RunOutcome(spec: spec, status: status, exitCode: code, spawnError: nil, seat: seat)
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
