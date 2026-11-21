import EventKit
import Foundation

/// Builds a `Diagnostics.Snapshot` from this Mac. Every probe is local and
/// short. Login checks are the non-billed status commands; their output is
/// interpreted and dropped, never stored.
enum DiagnosticsLive {
    /// `laneAuth`: the lane probe doctor already ran (`LaneProbe.snapshot`).
    /// When given, the lane-auth detector uses it instead of probing again,
    /// and covers every configured lane rather than only cursor and claude.
    static func findings(config: AgentsConfig?, laneAuth: [String: LanePreflight.AuthKind]? = nil,
                         now: Date = Date()) async -> [Diagnostics.Finding] {
        let settings = config?.doctor?.detectors
        var snap = await snapshot(config: config, settings: settings, now: now,
                                  probeLanes: laneAuth == nil)
        if let laneAuth, Diagnostics.enabled(Diagnostics.ID.laneAuth, settings) {
            snap.lanes = laneAuth.keys.sorted().map { lane in
                let state: Diagnostics.LaneState
                switch laneAuth[lane] {
                case .ready?: state = .ready
                case .needsHuman?: state = .needsHuman
                case .unreachable?, nil: state = .unknown
                }
                return Diagnostics.LaneCheck(lane: lane, state: state)
            }
        }
        return Diagnostics.collect(snapshot: snap, settings: settings)
    }

    static func snapshot(config: AgentsConfig?, settings: AgentsConfig.DetectorSettings?, now: Date,
                         probeLanes: Bool = true) async -> Diagnostics.Snapshot {
        var snap = Diagnostics.Snapshot(now: now)
        if Diagnostics.enabled(Diagnostics.ID.launchAgents, settings) {
            snap.launch = launchJob()
        }
        if Diagnostics.enabled(Diagnostics.ID.dispatcherLiveness, settings) {
            let (alive, rows) = running(config: config, now: now)
            snap.dispatcherAlive = alive
            snap.running = rows
        }
        if Diagnostics.enabled(Diagnostics.ID.disk, settings) {
            snap.disk = diskUse()
        }
        if Diagnostics.enabled(Diagnostics.ID.retriesExhausted, settings) {
            snap.retries = await retryTasks(maxRetries: config?.maxRetries ?? 0)
        }
        if probeLanes, Diagnostics.enabled(Diagnostics.ID.laneAuth, settings) {
            snap.lanes = laneChecks()
        }
        if Diagnostics.enabled(Diagnostics.ID.scheduledJobs, settings) {
            snap.jobs = cronJobs()
        }
        if Diagnostics.enabled(Diagnostics.ID.mcp, settings) {
            snap.mcp = mcpCheck()
        }
        if Diagnostics.enabled(Diagnostics.ID.deploymentDrift, settings) {
            snap.deployment = deployment()
        }
        if Diagnostics.enabled(Diagnostics.ID.permissions, settings) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            snap.permissions = [
                Diagnostics.PermissionCheck(name: "reminders", status: reminderStatus(status)),
                // Calendars too (#35): a rebuilt ad-hoc binary can keep Reminders
                // and lose Calendars, and calendar tasks then hang.
                Diagnostics.PermissionCheck(
                    name: "calendars", status: reminderStatus(EKEventStore.authorizationStatus(for: .event))),
            ]
        }
        await batch1(into: &snap, config: config, settings: settings, now: now)
        return snap
    }

    private static func configDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["APPLE_TASKS_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks", isDirectory: true)
    }

    private static func launchJob() -> Diagnostics.LaunchJob {
        let uid = getuid()
        let printed = (try? ProcessRunner.run(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["print", "gui/\(uid)/com.apple-tasks.dispatch"],
            timeout: 5))
        let loaded = printed?.status == 0 && printed?.timedOut != true
        let text = printed?.stdoutString ?? ""
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.apple-tasks.dispatch.plist")
        var interval: TimeInterval?
        if let data = try? Data(contentsOf: plist),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if let seconds = obj["StartInterval"] as? Int {
                interval = TimeInterval(seconds)
            } else if let seconds = obj["StartInterval"] as? Double {
                interval = seconds
            }
        }
        let logs = configDir().appendingPathComponent("logs", isDirectory: true)
        let stamps = ["dispatch.stdout.log", "dispatch.stderr.log"].compactMap { name -> Date? in
            let path = logs.appendingPathComponent(name).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return Diagnostics.LaunchJob(
            loaded: loaded,
            lastExitCode: loaded ? Diagnostics.launchctlInt(text, key: "last exit code") : nil,
            intervalSeconds: interval,
            lastPassAt: stamps.max())
    }

    private static func running(config: AgentsConfig?, now: Date) -> (Bool, [Diagnostics.RunningDispatch]) {
        let uid = getuid()
        let printed = try? ProcessRunner.run(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["print", "gui/\(uid)/com.apple-tasks.dispatch"],
            timeout: 5)
        let pid = printed.flatMap { Diagnostics.launchctlInt($0.stdoutString, key: "pid") }
        let alive: Bool
        if let pid, pid > 0 {
            errno = 0
            let result = kill(pid_t(pid), 0)
            alive = result == 0 || (result == -1 && errno == EPERM)
        } else {
            alive = false
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        let rows = AuditDB.shared.dispatchRows(status: "running", limit: 50).compactMap { row -> Diagnostics.RunningDispatch? in
            let started = isoFrac.date(from: row.startedAt) ?? iso.date(from: row.startedAt)
            guard let started else { return nil }
            let minutes = config?.agents[row.agent]?.timeoutMinutes ?? 60
            return Diagnostics.RunningDispatch(
                id: row.id, agent: row.agent,
                ageSeconds: now.timeIntervalSince(started),
                timeoutSeconds: TimeInterval(max(minutes, 1)) * 60)
        }
        return (alive, rows)
    }

    private static func diskUse() -> Diagnostics.DiskUse {
        let base = configDir()
        let logs = directoryBytes(base.appendingPathComponent("logs"))
        let runsDir = AppleTasksLayout.resolve().runs
        let runs = FileManager.default.fileExists(atPath: runsDir.path)
            ? directoryBytes(runsDir)
            : directoryBytes(base.appendingPathComponent("runs"))
        var worktrees: Int64 = 0
        var workComplete = true
        var seen = 0
        for row in AuditDB.shared.worktreeRows() {
            guard seen < 20 else { break }
            guard let path = row.worktree else { continue }
            seen += 1
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let measured = directoryBytes(URL(fileURLWithPath: path))
            worktrees += measured.bytes
            if !measured.complete { workComplete = false }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return Diagnostics.DiskUse(
            worktreeBytes: worktrees,
            worktreeComplete: workComplete,
            logBytes: logs.bytes + runs.bytes,
            logComplete: logs.complete && runs.complete,
            volumeFreeBytes: Int64(values?.volumeAvailableCapacity ?? 0),
            volumeTotalBytes: Int64(values?.volumeTotalCapacity ?? 0))
    }

    private static func directoryBytes(_ url: URL, limit: Int = 4000) -> (bytes: Int64, complete: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            return (0, false)
        }
        var bytes: Int64 = 0
        var seen = 0
        for case let file as URL in enumerator {
            seen += 1
            if seen > limit { return (bytes, false) }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        return (bytes, true)
    }

    private static func retryTasks(maxRetries: Int) async -> [Diagnostics.RetryTask] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = Store()
        guard (try? await store.requestAccess()) != nil else { return [] }
        let open = await store.reminders(in: nil)
        var out: [Diagnostics.RetryTask] = []
        for reminder in open where !reminder.isCompleted {
            let tags = Tags.parse(reminder.title ?? "").tags
            let ownFailed = tags.contains { ClaimTags.isFailed($0) && ClaimTags.isOwn($0) }
            guard ownFailed else { continue }
            let id = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
            let attempts = AuditDB.shared.failedAttempts(taskId: id).count
            out.append(Diagnostics.RetryTask(
                taskId: id, attempts: attempts, maxRetries: maxRetries, ownFailed: true))
            if out.count >= 20 { break }
        }
        return out
    }

    private static func laneChecks() -> [Diagnostics.LaneCheck] {
        var out: [Diagnostics.LaneCheck] = []
        let env = ProcessInfo.processInfo.environment
        if env["CURSOR_API_KEY"]?.isEmpty == false {
            out.append(Diagnostics.LaneCheck(lane: "cursor", state: .ready))
        } else if let exe = which("agent"),
                  let text = probe(exe, ["status", "--format", "json"]) {
            out.append(Diagnostics.LaneCheck(lane: "cursor", state: Diagnostics.interpretAgentStatus(text)))
        }
        if env["ANTHROPIC_API_KEY"]?.isEmpty == false {
            out.append(Diagnostics.LaneCheck(lane: "claude", state: .ready))
        } else if let exe = which("claude"),
                  let text = probe(exe, ["auth", "status", "--text"]) {
            out.append(Diagnostics.LaneCheck(lane: "claude", state: Diagnostics.interpretClaudeAuth(text)))
        }
        return out
    }

    private static func cronJobs() -> [Diagnostics.ScheduledJob] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/cron/jobs.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = obj["jobs"] as? [[String: Any]] else { return [] }
        return jobs.map { job in
            let name = (job["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (job["id"] as? String)
                ?? "job"
            return Diagnostics.ScheduledJob(
                name: name,
                lastStatus: job["last_status"] as? String ?? "never",
                provider: job["provider"] as? String,
                lastError: job["last_error"] as? String)
        }
    }

    private static func mcpCheck() -> Diagnostics.MCPCheck? {
        guard let root = BuildInfo.sourceRoot, !root.isEmpty else { return nil }
        let entry = URL(fileURLWithPath: root).appendingPathComponent("mcp/src/server.ts")
        return Diagnostics.MCPCheck(
            runtimeFound: which("bun") != nil,
            entryFound: FileManager.default.fileExists(atPath: entry.path))
    }

    private static func deployment() -> Diagnostics.DeploymentCheck {
        let status = Doctor.deploymentStatus()
        let drifted = status.binaryMatchesHead == false || status.binaryOlderThanCliCommit == true
        return Diagnostics.DeploymentCheck(drifted: drifted, note: status.note)
    }

    private static func reminderStatus(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown"
        }
    }

    private static func which(_ name: String) -> String? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/which"), [name], timeout: 2),
              result.status == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func probe(_ executable: String, _ args: [String]) -> String? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: executable), args, timeout: 5),
              !result.timedOut else { return nil }
        return result.stdoutString
    }
}
