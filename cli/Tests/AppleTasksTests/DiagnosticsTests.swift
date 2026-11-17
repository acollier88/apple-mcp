import XCTest
@testable import apple_tasks

final class DiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDoctorDetectorSettingsDecode() throws {
        let json = """
        {"agents":{},"doctor":{"detectors":{"enabled":["disk","mcp"],"disabled":["disk"],"thresholds":{"healDailyCap":1,"volumeFreePercent":10,"launchSilentIntervals":4}}}}
        """
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        let settings = config.doctor?.detectors
        XCTAssertEqual(settings?.thresholds?.healDailyCap, 1)
        XCTAssertFalse(Diagnostics.enabled(Diagnostics.ID.disk, settings))
        XCTAssertTrue(Diagnostics.enabled(Diagnostics.ID.mcp, settings))
        XCTAssertFalse(Diagnostics.enabled(Diagnostics.ID.laneAuth, settings))
        let limits = Diagnostics.thresholds(settings)
        XCTAssertEqual(limits.healDailyCap, 1)
        XCTAssertEqual(limits.volumeFreeFraction, 0.10, accuracy: 0.0001)
        XCTAssertEqual(limits.launchSilentIntervals, 4)
    }

    func testLaunchJobNotLoadedExitAndSilence() {
        let missing = Diagnostics.launchAgents(
            .init(loaded: false, lastExitCode: 1, intervalSeconds: 60, lastPassAt: nil),
            now: now, silentIntervals: 2)
        XCTAssertEqual(missing.map(\.signature), ["launch-not-loaded"])
        XCTAssertEqual(missing.first?.kind, .healable)

        let loaded = Diagnostics.launchAgents(
            .init(loaded: true, lastExitCode: 75, intervalSeconds: 60, lastPassAt: now.addingTimeInterval(-300)),
            now: now, silentIntervals: 2)
        XCTAssertEqual(loaded.map(\.signature), ["launch-exit-75", "launch-silent"])

        let fresh = Diagnostics.launchAgents(
            .init(loaded: true, lastExitCode: 0, intervalSeconds: 60, lastPassAt: now.addingTimeInterval(-30)),
            now: now, silentIntervals: 2)
        XCTAssertTrue(fresh.isEmpty)
    }

    func testDispatcherHangRequiresALiveDispatcher() {
        let row = Diagnostics.RunningDispatch(id: 9, agent: "cursor", ageSeconds: 4000, timeoutSeconds: 3600)
        XCTAssertTrue(Diagnostics.dispatcherLiveness(alive: false, rows: [row]).isEmpty)
        let hung = Diagnostics.dispatcherLiveness(alive: true, rows: [row])
        XCTAssertEqual(hung.first?.signature, "dispatcher-hung")
        XCTAssertEqual(hung.first?.kind, .healable)
        XCTAssertTrue(hung.first?.evidence.contains("#9 cursor") == true)
        let within = Diagnostics.RunningDispatch(id: 1, agent: "cursor", ageSeconds: 10, timeoutSeconds: 3600)
        XCTAssertTrue(Diagnostics.dispatcherLiveness(alive: true, rows: [within]).isEmpty)
    }

    func testDiskThresholdsAndIncompleteWalks() {
        let limits = Diagnostics.Thresholds.standard
        let partial = Diagnostics.DiskUse(
            worktreeBytes: limits.worktreeBytes + 1, worktreeComplete: false,
            logBytes: limits.logBytes + 1, logComplete: false,
            volumeFreeBytes: 1, volumeTotalBytes: 100)
        let partialFindings = Diagnostics.diskFindings(partial, limits: limits)
        XCTAssertEqual(partialFindings.map(\.signature), ["disk-volume"])

        let full = Diagnostics.DiskUse(
            worktreeBytes: limits.worktreeBytes, worktreeComplete: true,
            logBytes: limits.logBytes, logComplete: true,
            volumeFreeBytes: 50, volumeTotalBytes: 100)
        XCTAssertEqual(Diagnostics.diskFindings(full, limits: limits).map(\.signature),
                       ["disk-worktrees", "disk-logs"])
    }

    func testRetriesStayWithAPerson() {
        let tasks = [
            Diagnostics.RetryTask(taskId: "a", attempts: 1, maxRetries: 0, ownFailed: true),
            Diagnostics.RetryTask(taskId: "b", attempts: 2, maxRetries: 2, ownFailed: true),
            Diagnostics.RetryTask(taskId: "c", attempts: 3, maxRetries: 2, ownFailed: true),
            Diagnostics.RetryTask(taskId: "d", attempts: 9, maxRetries: 0, ownFailed: false),
        ]
        let findings = Diagnostics.retriesExhausted(tasks)
        XCTAssertEqual(findings.map(\.signature), ["retries-exhausted:a", "retries-exhausted:c"])
        XCTAssertTrue(findings.allSatisfy { $0.kind == .needsHuman })
    }

    func testLaneAuthParsersDoNotTreatNotLoggedInAsReady() {
        XCTAssertEqual(Diagnostics.interpretClaudeAuth("Not logged in. Run claude auth login"), .needsHuman)
        XCTAssertEqual(
            Diagnostics.interpretClaudeAuth("Auth token: claude.ai · not in use\nAPI key: ANTHROPIC_API_KEY"),
            .ready)
        XCTAssertEqual(Diagnostics.interpretAgentStatus(#"{"isAuthenticated":false,"email":"hidden@example.com"}"#), .needsHuman)
        XCTAssertEqual(Diagnostics.interpretAgentStatus(#"{"isAuthenticated":true}"#), .ready)
        let findings = Diagnostics.laneAuth([
            .init(lane: "cursor", state: .needsHuman),
            .init(lane: "claude", state: .ready),
            .init(lane: "hermes", state: .unknown),
        ])
        XCTAssertEqual(findings.map(\.signature), ["lane-auth-missing:cursor"])
        XCTAssertFalse(findings[0].evidence.contains("@"))
        XCTAssertEqual(findings[0].kind, .needsHuman)
    }

    func testScheduledJobsSplitCredentialFromFailure() {
        let jobs = [
            Diagnostics.ScheduledJob(name: "stale", lastStatus: "error", provider: "ollama-launch", lastError: "Copilot 403"),
            Diagnostics.ScheduledJob(name: "login", lastStatus: "error", provider: "copilot", lastError: "HTTP 401 unauthorized"),
            Diagnostics.ScheduledJob(name: "crash", lastStatus: "failed", provider: "ollama-launch", lastError: "exit 1"),
            Diagnostics.ScheduledJob(name: "ok", lastStatus: "ok", provider: nil, lastError: "old"),
            Diagnostics.ScheduledJob(name: "secret", lastStatus: "error", provider: nil, lastError: "bearer sk-secret"),
        ]
        let findings = Diagnostics.scheduledJobs(jobs)
        XCTAssertEqual(findings.map(\.signature), [
            "scheduled-blocked:login", "scheduled-failing:crash", "scheduled-blocked:secret",
        ])
        XCTAssertEqual(findings[0].kind, .needsHuman)
        XCTAssertEqual(findings[1].kind, .healable)
        XCTAssertEqual(findings[2].evidence.contains("sk-"), false)
        XCTAssertTrue(findings[2].evidence.contains("[redacted]"))
    }

    func testMCPDeploymentAndPermissions() {
        XCTAssertTrue(Diagnostics.mcpReachability(.init(runtimeFound: true, entryFound: true)).isEmpty)
        XCTAssertEqual(Diagnostics.mcpReachability(.init(runtimeFound: false, entryFound: true)).first?.signature, "mcp-unavailable")
        XCTAssertEqual(Diagnostics.deploymentDrift(.init(drifted: false, note: "ok")).count, 0)
        let drift = Diagnostics.deploymentDrift(.init(drifted: true, note: "behind HEAD"))
        XCTAssertEqual(drift.first?.kind, .needsHuman)
        XCTAssertTrue(Diagnostics.permissions([.init(name: "reminders", status: "fullAccess")]).isEmpty)
        let denied = Diagnostics.permissions([.init(name: "reminders", status: "denied")])
        XCTAssertEqual(denied.first?.kind, .needsHuman)
        XCTAssertEqual(denied.first?.signature, "permission-missing:reminders")
    }

    func testDisabledDetectorIsOmitted() {
        var settings = AgentsConfig.DetectorSettings()
        settings.disabled = [Diagnostics.ID.disk]
        let limits = Diagnostics.Thresholds.standard
        let snapshot = Diagnostics.Snapshot(
            now: now,
            disk: .init(worktreeBytes: limits.worktreeBytes, worktreeComplete: true,
                        logBytes: 0, logComplete: true,
                        volumeFreeBytes: 1, volumeTotalBytes: 100))
        let findings = Diagnostics.collect(snapshot: snapshot, settings: settings)
        XCTAssertTrue(findings.isEmpty)
    }

    func testHealGateCooldownCapAndDayRollover() {
        var state = Diagnostics.HealLedgerState(
            lastEnqueued: ["hermes": now.addingTimeInterval(-3600)],
            day: Diagnostics.dayString(now),
            count: 3)
        XCTAssertEqual(
            Diagnostics.gate(signature: "hermes", now: now, state: state, cooldown: 7200, dailyCap: 3),
            .cooldown)
        XCTAssertEqual(
            Diagnostics.gate(signature: "disk-volume", now: now, state: state, cooldown: 7200, dailyCap: 3),
            .capped)
        state.count = 1
        state.lastEnqueued = [:]
        XCTAssertEqual(
            Diagnostics.gate(signature: "disk-volume", now: now, state: state, cooldown: 7200, dailyCap: 3),
            .enqueue)
        state.day = "1999-01-01"
        state.count = 9
        XCTAssertEqual(
            Diagnostics.gate(signature: "disk-volume", now: now, state: state, cooldown: 7200, dailyCap: 3),
            .enqueue)
        let marked = Diagnostics.marked(state, signature: "disk-volume", now: now)
        XCTAssertEqual(marked.day, Diagnostics.dayString(now))
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.lastEnqueued["disk-volume"], now)
    }

    func testLaunchctlIntAndIssueOmitsEmptyKind() throws {
        let text = "\tstate = running\n\tpid = 4242\n\tlast exit code = 0\n"
        XCTAssertEqual(Diagnostics.launchctlInt(text, key: "pid"), 4242)
        XCTAssertEqual(Diagnostics.launchctlInt(text, key: "last exit code"), 0)
        let data = try JSONEncoder().encode(DoctorIssue(
            system: "hermes", severity: "red", summary: "down", signature: "hermes"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["kind"])
        XCTAssertEqual(obj?["signature"] as? String, "hermes")
    }
}
