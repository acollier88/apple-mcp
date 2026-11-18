import Foundation

/// Proactive diagnostics (#47). Detectors are pure functions over a snapshot
/// the caller injects. They never read the disk, the ledger, or a login.
enum Diagnostics {
    enum ID {
        static let launchAgents = "launchAgents"
        static let dispatcherLiveness = "dispatcherLiveness"
        static let disk = "disk"
        static let retriesExhausted = "retriesExhausted"
        static let laneAuth = "laneAuth"
        static let scheduledJobs = "scheduledJobs"
        static let mcp = "mcp"
        static let deploymentDrift = "deploymentDrift"
        static let permissions = "permissions"
        static let all = [
            launchAgents, dispatcherLiveness, disk, retriesExhausted, laneAuth,
            scheduledJobs, mcp, deploymentDrift, permissions,
        ]
    }

    enum Kind: String, Equatable {
        case healable
        case needsHuman = "needs-human"
    }

    struct Finding: Equatable {
        let signature: String
        let system: String
        let severity: String
        let kind: Kind
        let summary: String
        let evidence: String
        let suggestedAction: String

        var issue: DoctorIssue {
            DoctorIssue(system: system, severity: severity, summary: summary,
                        signature: signature, kind: kind.rawValue,
                        evidence: evidence, suggestedAction: suggestedAction)
        }
    }

    struct Thresholds: Equatable {
        var launchSilentIntervals: Int
        var worktreeBytes: Int64
        var logBytes: Int64
        var volumeFreeFraction: Double
        var healCooldownHours: Int
        var healDailyCap: Int

        static let standard = Thresholds(
            launchSilentIntervals: 2,
            worktreeBytes: 2_048 * 1024 * 1024,
            logBytes: 512 * 1024 * 1024,
            volumeFreeFraction: 0.05,
            healCooldownHours: 24,
            healDailyCap: 3)
    }

    struct LaunchJob: Equatable {
        var loaded: Bool
        var lastExitCode: Int?
        /// Seconds between launchd runs. Nil when the plist has no StartInterval.
        var intervalSeconds: TimeInterval?
        var lastPassAt: Date?
    }

    struct RunningDispatch: Equatable {
        var id: Int
        var agent: String
        var ageSeconds: TimeInterval
        var timeoutSeconds: TimeInterval
    }

    struct DiskUse: Equatable {
        var worktreeBytes: Int64
        var worktreeComplete: Bool
        var logBytes: Int64
        var logComplete: Bool
        var volumeFreeBytes: Int64
        var volumeTotalBytes: Int64
    }

    struct RetryTask: Equatable {
        var taskId: String
        var attempts: Int
        var maxRetries: Int
        var ownFailed: Bool
    }

    enum LaneState: Equatable {
        case ready
        case needsHuman
        case unknown
    }

    struct LaneCheck: Equatable {
        var lane: String
        var state: LaneState
    }

    struct ScheduledJob: Equatable {
        var name: String
        var lastStatus: String
        var provider: String?
        var lastError: String?
    }

    struct MCPCheck: Equatable {
        var runtimeFound: Bool
        var entryFound: Bool
    }

    struct DeploymentCheck: Equatable {
        var drifted: Bool
        var note: String
    }

    struct PermissionCheck: Equatable {
        var name: String
        var status: String
    }

    struct Snapshot: Equatable {
        var now: Date
        var launch: LaunchJob?
        var dispatcherAlive: Bool
        var running: [RunningDispatch]
        var disk: DiskUse?
        var retries: [RetryTask]
        var lanes: [LaneCheck]
        var jobs: [ScheduledJob]
        var mcp: MCPCheck?
        var deployment: DeploymentCheck?
        var permissions: [PermissionCheck]

        init(now: Date = Date(),
             launch: LaunchJob? = nil,
             dispatcherAlive: Bool = false,
             running: [RunningDispatch] = [],
             disk: DiskUse? = nil,
             retries: [RetryTask] = [],
             lanes: [LaneCheck] = [],
             jobs: [ScheduledJob] = [],
             mcp: MCPCheck? = nil,
             deployment: DeploymentCheck? = nil,
             permissions: [PermissionCheck] = []) {
            self.now = now
            self.launch = launch
            self.dispatcherAlive = dispatcherAlive
            self.running = running
            self.disk = disk
            self.retries = retries
            self.lanes = lanes
            self.jobs = jobs
            self.mcp = mcp
            self.deployment = deployment
            self.permissions = permissions
        }
    }

    struct HealLedgerState: Equatable {
        var lastEnqueued: [String: Date]
        var day: String
        var count: Int

        static let empty = HealLedgerState(lastEnqueued: [:], day: "", count: 0)
    }

    enum HealGate: Equatable {
        case enqueue
        case cooldown
        case capped
    }

    static func enabled(_ id: String, _ settings: AgentsConfig.DetectorSettings?) -> Bool {
        if settings?.disabled?.contains(id) == true { return false }
        if let allow = settings?.enabled { return allow.contains(id) }
        return true
    }

    static func thresholds(_ settings: AgentsConfig.DetectorSettings?) -> Thresholds {
        var out = Thresholds.standard
        guard let raw = settings?.thresholds else { return out }
        if let n = raw.launchSilentIntervals, n >= 1 { out.launchSilentIntervals = n }
        if let mb = raw.worktreeMegabytes, mb > 0 {
            out.worktreeBytes = Int64(mb) * 1024 * 1024
        }
        if let mb = raw.logMegabytes, mb > 0 {
            out.logBytes = Int64(mb) * 1024 * 1024
        }
        if let pct = raw.volumeFreePercent, pct > 0, pct < 100 {
            out.volumeFreeFraction = pct / 100
        }
        if let hours = raw.healCooldownHours, hours >= 0 { out.healCooldownHours = hours }
        if let cap = raw.healDailyCap, cap >= 0 { out.healDailyCap = cap }
        return out
    }

    static func collect(snapshot: Snapshot, settings: AgentsConfig.DetectorSettings?) -> [Finding] {
        let limits = thresholds(settings)
        var out: [Finding] = []
        func take(_ id: String, _ findings: [Finding]) {
            guard enabled(id, settings) else { return }
            out.append(contentsOf: findings)
        }
        if let launch = snapshot.launch {
            take(ID.launchAgents, launchAgents(launch, now: snapshot.now, silentIntervals: limits.launchSilentIntervals))
        }
        take(ID.dispatcherLiveness, dispatcherLiveness(alive: snapshot.dispatcherAlive, rows: snapshot.running))
        if let disk = snapshot.disk {
            take(ID.disk, diskFindings(disk, limits: limits))
        }
        take(ID.retriesExhausted, retriesExhausted(snapshot.retries))
        take(ID.laneAuth, laneAuth(snapshot.lanes))
        take(ID.scheduledJobs, scheduledJobs(snapshot.jobs))
        if let mcp = snapshot.mcp {
            take(ID.mcp, mcpReachability(mcp))
        }
        if let deployment = snapshot.deployment {
            take(ID.deploymentDrift, deploymentDrift(deployment))
        }
        take(ID.permissions, permissions(snapshot.permissions))
        return out
    }

    static func launchAgents(_ job: LaunchJob, now: Date, silentIntervals: Int) -> [Finding] {
        let reload = "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.apple-tasks.dispatch.plist"
        if !job.loaded {
            return [Finding(
                signature: "launch-not-loaded",
                system: "launchd",
                severity: "red",
                kind: .healable,
                summary: "com.apple-tasks.dispatch is not loaded",
                evidence: "launchctl print gui/$(id -u)/com.apple-tasks.dispatch failed",
                suggestedAction: reload)]
        }
        var out: [Finding] = []
        if let code = job.lastExitCode, code != 0 {
            out.append(Finding(
                signature: "launch-exit-\(code)",
                system: "launchd",
                severity: "red",
                kind: .healable,
                summary: "com.apple-tasks.dispatch last exited \(code)",
                evidence: "last exit code = \(code)",
                suggestedAction: "Read ~/.config/apple-tasks/logs/dispatch.stderr.log, fix the crash, then \(reload)"))
        }
        if let interval = job.intervalSeconds, interval > 0 {
            let limit = interval * TimeInterval(max(silentIntervals, 1))
            let stale: Bool
            if let last = job.lastPassAt {
                stale = now.timeIntervalSince(last) > limit
            } else {
                stale = true
            }
            if stale {
                let seen = job.lastPassAt.map { "last log activity \($0)" } ?? "no dispatch log"
                out.append(Finding(
                    signature: "launch-silent",
                    system: "launchd",
                    severity: "yellow",
                    kind: .healable,
                    summary: "dispatch has not logged a pass in \(silentIntervals) intervals",
                    evidence: "\(seen); StartInterval \(Int(interval))s",
                    suggestedAction: "Confirm the job is running (`launchctl print gui/$(id -u)/com.apple-tasks.dispatch`) and that ~/.config/apple-tasks/logs/dispatch.stderr.log is being written."))
            }
        }
        return out
    }

    static func dispatcherLiveness(alive: Bool, rows: [RunningDispatch]) -> [Finding] {
        guard alive else { return [] }
        let hung = rows.filter { $0.ageSeconds > $0.timeoutSeconds }
        guard !hung.isEmpty else { return [] }
        let evidence = hung.map { "#\($0.id) \($0.agent) age \(Int($0.ageSeconds))s > timeout \(Int($0.timeoutSeconds))s" }
            .joined(separator: "; ")
        return [Finding(
            signature: "dispatcher-hung",
            system: "dispatch",
            severity: "red",
            kind: .healable,
            summary: "dispatcher is still alive with a run past its timeout",
            evidence: evidence,
            suggestedAction: "Stop the stuck job with `launchctl bootout gui/$(id -u)/com.apple-tasks.dispatch`, then bootstrap the plist again. Do not delete ledger rows by hand.")]
    }

    static func diskFindings(_ disk: DiskUse, limits: Thresholds) -> [Finding] {
        var out: [Finding] = []
        if disk.worktreeComplete, disk.worktreeBytes >= limits.worktreeBytes {
            out.append(Finding(
                signature: "disk-worktrees",
                system: "disk",
                severity: "yellow",
                kind: .healable,
                summary: "agent worktrees are \(disk.worktreeBytes) bytes",
                evidence: "worktree bytes \(disk.worktreeBytes); threshold \(limits.worktreeBytes)",
                suggestedAction: "Remove merged worktrees with `apple-tasks dispatch --reap-only` (GC runs unless --no-gc). Do not delete branches that are not merged."))
        }
        if disk.logComplete, disk.logBytes >= limits.logBytes {
            out.append(Finding(
                signature: "disk-logs",
                system: "disk",
                severity: "yellow",
                kind: .healable,
                summary: "dispatch logs and run files are \(disk.logBytes) bytes",
                evidence: "log bytes \(disk.logBytes); threshold \(limits.logBytes)",
                suggestedAction: "Delete old files under ~/.config/apple-tasks/logs and ~/.config/apple-tasks/runs whose ledger rows are already finished. Do not delete a log for a row still marked running."))
        }
        if disk.volumeTotalBytes > 0 {
            let free = Double(disk.volumeFreeBytes) / Double(disk.volumeTotalBytes)
            if free < limits.volumeFreeFraction {
                let pct = Int(free * 100)
                out.append(Finding(
                    signature: "disk-volume",
                    system: "disk",
                    severity: "red",
                    kind: .healable,
                    summary: "volume is \(pct)% free",
                    evidence: "free \(disk.volumeFreeBytes) of \(disk.volumeTotalBytes)",
                    suggestedAction: "Free space on the volume that holds ~/.config/apple-tasks. Start with finished run logs and merged worktrees. Do not delete the ledger database."))
            }
        }
        return out
    }

    static func retriesExhausted(_ tasks: [RetryTask]) -> [Finding] {
        tasks.compactMap { task in
            guard task.ownFailed else { return nil }
            let exhausted = task.maxRetries <= 0 || task.attempts > task.maxRetries
            guard exhausted else { return nil }
            return Finding(
                signature: "retries-exhausted:\(task.taskId)",
                system: "dispatch",
                severity: "yellow",
                kind: .needsHuman,
                summary: "task \(task.taskId) has no retries left",
                evidence: "\(task.attempts) failures, maxRetries \(task.maxRetries)",
                suggestedAction: "A person decides whether to edit the task or run `apple-tasks dispatch-retry \(task.taskId)`. Do not enqueue another heal for it.")
        }
    }

    static func laneAuth(_ lanes: [LaneCheck]) -> [Finding] {
        lanes.compactMap { lane in
            guard lane.state == .needsHuman else { return nil }
            return Finding(
                signature: "lane-auth-missing:\(lane.lane)",
                system: "auth",
                severity: "yellow",
                kind: .needsHuman,
                summary: "\(lane.lane) is not logged in",
                evidence: "\(lane.lane): login missing or expired",
                suggestedAction: lane.lane == "claude"
                    ? "Run `claude auth login` in a terminal. A heal agent must not look for API keys."
                    : "Run `agent login` in a terminal. A heal agent must not look for API keys.")
        }
    }

    /// `agent status --format json`. Only the boolean is read. Free text
    /// never counts as logged-in, because "not logged in" contains "logged in".
    static func interpretAgentStatus(_ text: String) -> LaneState {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = obj["isAuthenticated"] as? Bool {
                return value ? .ready : .needsHuman
            }
            if let user = obj["user"] as? [String: Any],
               let value = user["isAuthenticated"] as? Bool {
                return value ? .ready : .needsHuman
            }
        }
        let lower = text.lowercased()
        if lower.contains("not logged") || lower.contains("login required") {
            return .needsHuman
        }
        return .unknown
    }

    /// `claude auth status --text`. "not logged" is tested before "logged in".
    static func interpretClaudeAuth(_ text: String) -> LaneState {
        let lower = text.lowercased()
        if lower.contains("not logged") || lower.contains("login required") {
            return .needsHuman
        }
        if lower.contains("api key:") || lower.contains("logged in") {
            return .ready
        }
        return .unknown
    }

    static func scheduledJobs(_ jobs: [ScheduledJob]) -> [Finding] {
        jobs.compactMap { job in
            let status = job.lastStatus.lowercased()
            let error = (job.lastError ?? "").lowercased()
            let failing = status == "error" || status == "failed" || status == "failure" || status == "blocked"
            guard failing else { return nil }
            let provider = job.provider?.lowercased() ?? ""
            if provider == "ollama-launch", error.contains("403") || error.contains("copilot") {
                return nil
            }
            let credential = error.contains("401") || error.contains("403")
                || error.contains("unauthorized") || error.contains("forbidden")
                || error.contains("credential") || error.contains("api key")
                || error.contains("not logged") || error.contains("login required")
                || error.contains("bearer ") || error.contains("sk-")
                || (job.lastError ?? "").range(of: #"eyJ[A-Za-z0-9_-]{20,}"#, options: .regularExpression) != nil
            let blocked = status == "blocked" || error.contains("blocked_config") || error.contains("blocked")
            let needsPerson = credential || blocked
            let detail = redact(job.lastError ?? job.lastStatus)
            return Finding(
                signature: (needsPerson ? "scheduled-blocked:" : "scheduled-failing:") + job.name,
                system: "scheduler",
                severity: needsPerson ? "yellow" : "red",
                kind: needsPerson ? .needsHuman : .healable,
                summary: needsPerson
                    ? "scheduled job \(job.name) needs a person"
                    : "scheduled job \(job.name) is failing",
                evidence: "\(job.name) status=\(job.lastStatus) \(detail)",
                suggestedAction: needsPerson
                    ? "A person has to fix the login or config for \(job.name). Do not search for tokens."
                    : "Inspect ~/.hermes/cron/jobs.json for \(job.name) and repair the job command. Do not print or rotate secrets.")
        }
    }

    static func mcpReachability(_ check: MCPCheck) -> [Finding] {
        if check.entryFound && check.runtimeFound { return [] }
        let why = !check.entryFound ? "mcp/src/server.ts is missing" : "bun is not on PATH"
        return [Finding(
            signature: "mcp-unavailable",
            system: "mcp",
            severity: "yellow",
            kind: .healable,
            summary: "the apple-tasks MCP server cannot start",
            evidence: why,
            suggestedAction: !check.entryFound
                ? "Restore mcp/src/server.ts in the source checkout doctor was built from. Do not look for credentials."
                : "Install bun and run `make mcp` in the apple-mcp checkout. Do not look for credentials.")]
    }

    static func deploymentDrift(_ check: DeploymentCheck) -> [Finding] {
        guard check.drifted else { return [] }
        return [Finding(
            signature: "deployment-drift",
            system: "deployment",
            severity: "yellow",
            kind: .needsHuman,
            summary: "the launchd binary does not match the source checkout",
            evidence: redact(check.note, limit: 240),
            suggestedAction: "From the source checkout, run `make install` when you mean to ship it. A heal agent must not redeploy on its own.")]
    }

    static func permissions(_ grants: [PermissionCheck]) -> [Finding] {
        grants.compactMap { grant in
            let status = grant.status.lowercased()
            let missing = status.contains("denied") || status.contains("restricted")
                || status.contains("notdetermined") || status.contains("writeonly")
            guard missing else { return nil }
            return Finding(
                signature: "permission-missing:\(grant.name)",
                system: "permissions",
                severity: "yellow",
                kind: .needsHuman,
                summary: "\(grant.name) access is \(grant.status)",
                evidence: "\(grant.name): \(grant.status)",
                suggestedAction: "Grant \(grant.name) to the process that runs dispatch, in System Settings > Privacy & Security. A heal agent cannot click that prompt.")
        }
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether this signature may create a heal task right now. Does not
    /// mutate `state`; on `.enqueue` the caller applies `marked`.
    static func gate(signature: String, now: Date, state: HealLedgerState,
                     cooldown: TimeInterval, dailyCap: Int) -> HealGate {
        let day = dayString(now)
        let count = state.day == day ? state.count : 0
        if let last = state.lastEnqueued[signature], now.timeIntervalSince(last) < cooldown {
            return .cooldown
        }
        if count >= max(dailyCap, 0) { return .capped }
        return .enqueue
    }

    static func marked(_ state: HealLedgerState, signature: String, now: Date) -> HealLedgerState {
        var next = state
        let day = dayString(now)
        if next.day != day {
            next.day = day
            next.count = 0
        }
        next.count += 1
        next.lastEnqueued[signature] = now
        return next
    }

    static func redact(_ raw: String, limit: Int = 120) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.range(of: #"eyJ[A-Za-z0-9_-]{20,}"#, options: .regularExpression) != nil
            || flat.lowercased().contains("bearer ")
            || flat.contains("sk-") {
            return "[redacted]"
        }
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// First integer on a `key = value` line of `launchctl print` output.
    static func launchctlInt(_ text: String, key: String) -> Int? {
        let prefix = "\(key) = "
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let rest = trimmed.dropFirst(prefix.count)
            let digits = rest.prefix { $0 == "-" || $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}
