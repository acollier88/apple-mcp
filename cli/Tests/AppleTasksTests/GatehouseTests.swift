import XCTest
@testable import apple_tasks

/// Issue #39. No test launches `gate`, touches the network, or migrates the
/// real ~/.config/apple-tasks directory. Path fixtures use a temp directory
/// or an explicit home URL that is never created.
final class GatehouseTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sandbox(mode: String = "gatehouse", net: String? = "outbound",
                         preset: String? = "cursor") -> AgentsConfig.Sandbox {
        AgentsConfig.Sandbox(mode: mode, net: net, preset: preset)
    }

    // MARK: plan argv

    func testUnsandboxedPlanArgvIsUnchanged() {
        let argv = ["agent", "-p", "hi", "--sandbox", "disabled", "--force"]
        let planned = Dispatch.planArgv(
            argv: argv, sandbox: nil, workspace: "/wt", repo: "/repo",
            envPassthrough: ["CURSOR_API_KEY"])
        XCTAssertEqual(planned, argv)
    }

    func testUnknownSandboxModeDoesNotWrap() {
        let argv = ["agent", "-p", "hi"]
        let planned = Dispatch.planArgv(
            argv: argv, sandbox: sandbox(mode: "off"), workspace: "/wt", repo: "/repo",
            envPassthrough: [])
        XCTAssertEqual(planned, argv)
    }

    func testPlanWrapsGatehouseLaneAndStripsNestedSandbox() {
        let argv = ["agent", "-p", "{prompt}", "--sandbox", "disabled", "--force", "--trust"]
        let planned = Dispatch.planArgv(
            argv: argv, sandbox: sandbox(), workspace: "/support/worktrees/4",
            repo: "/repos/apple-mcp", envPassthrough: ["CURSOR_API_KEY"])
        XCTAssertEqual(planned, [
            "gate", "sandbox",
            "--workspace", "/support/worktrees/4",
            "--git-dir", "/repos/apple-mcp/.git",
            "--net", "outbound",
            "--preset", "cursor",
            "--env", "CURSOR_API_KEY",
            "--",
            "agent", "-p", "{prompt}", "--force", "--trust",
        ])
        XCTAssertFalse(planned.contains("--sandbox"))
        XCTAssertFalse(planned.contains("disabled"))
    }

    func testScratchLaneOmitsGitDir() {
        let planned = Dispatch.planArgv(
            argv: ["agent", "-p", "x", "--sandbox=disabled"],
            sandbox: sandbox(preset: nil), workspace: "/support/scratch/9",
            repo: nil, envPassthrough: ["", "A", "B"])
        XCTAssertFalse(planned.contains("--git-dir"))
        XCTAssertFalse(planned.contains("--preset"))
        XCTAssertFalse(planned.contains("--sandbox=disabled"))
        XCTAssertEqual(planned, [
            "gate", "sandbox",
            "--workspace", "/support/scratch/9",
            "--net", "outbound",
            "--env", "A",
            "--env", "B",
            "--",
            "agent", "-p", "x",
        ])
    }

    func testBareHarnessSandboxFlagIsStrippedOnlyWhenWrapped() {
        let argv = ["agy", "-p", "x", "--sandbox", "--dangerously-skip-permissions"]
        XCTAssertEqual(
            Dispatch.planArgv(argv: argv, sandbox: nil, workspace: "/wt", repo: "/r", envPassthrough: []),
            argv)
        let planned = Dispatch.planArgv(
            argv: argv, sandbox: sandbox(net: nil, preset: nil),
            workspace: "/wt", repo: "/r", envPassthrough: [])
        XCTAssertTrue(planned.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(planned.contains("--sandbox"))
        XCTAssertTrue(planned.contains("--git-dir"))
    }

    func testLaneArgvSeesCursorInsideWrapper() {
        let planned = Dispatch.planArgv(
            argv: ["agent", "--model", "auto", "--sandbox", "disabled"],
            sandbox: sandbox(), workspace: "/wt", repo: "/repo", envPassthrough: [])
        let streamed = Dispatch.mapLaneArgv(planned, AgentSeat.withStreamJSON)
        let lane = Dispatch.laneArgv(streamed)
        XCTAssertEqual(streamed.first, "gate")
        XCTAssertTrue(AgentSeat.isCursorAgent(lane))
        XCTAssertEqual(AgentSeat.from(argv: lane).provider, "cursor")
        XCTAssertEqual(lane.suffix(2), ["--output-format", "stream-json"])
        XCTAssertFalse(lane.contains("--sandbox"))
    }

    // MARK: prompts

    func testSandboxedPromptPrefixesWriteBackOnly() {
        let prompt = """
        apple-tasks update T1 --append-notes "x"
        apple-tasks complete T1
        apple-tasks notes create --title "t"
        apple-tasks notify --push
        apple-tasks approve request "ok?"
        apple-tasks approve check TOK
        apple-tasks secret get ntfy.topic
        apple-tasks approve answer TOK approve
        apple-tasks dispatch --dry-run
        apple-tasks dispatch-retry
        apple-tasks serve
        apple-tasks web fetch "https://example.com"
        gate run -- apple-tasks update T1 --append-notes "y"
        """
        let out = PromptTemplate.prefixGateRun(prompt)
        XCTAssertTrue(out.contains("gate run -- apple-tasks update T1 --append-notes \"x\""))
        XCTAssertTrue(out.contains("gate run -- apple-tasks complete T1"))
        XCTAssertTrue(out.contains("gate run -- apple-tasks notes create"))
        XCTAssertTrue(out.contains("gate run -- apple-tasks notify --push"))
        XCTAssertTrue(out.contains("gate run -- apple-tasks approve request"))
        XCTAssertTrue(out.contains("gate run -- apple-tasks approve check TOK"))
        XCTAssertFalse(out.contains("gate run -- apple-tasks secret"))
        XCTAssertFalse(out.contains("gate run -- apple-tasks approve answer"))
        XCTAssertFalse(out.contains("gate run -- apple-tasks dispatch"))
        XCTAssertFalse(out.contains("gate run -- apple-tasks serve"))
        XCTAssertFalse(out.contains("gate run -- apple-tasks web fetch"))
        XCTAssertEqual(out.components(separatedBy: "gate run -- gate run --").count, 1)
        let plain = Dispatch.taskPrompt(
            template: AgentsConfig.defaultPromptTemplate, taskId: "T1", list: "L",
            title: "Hi", notes: nil, claimTag: "dispatched:mac")
        XCTAssertFalse(plain.contains("gate run --"))
        XCTAssertTrue(plain.contains("apple-tasks complete T1"))
    }

    // MARK: layout

    func testRuntimePathsResolveUnderSupportRoot() {
        let home = URL(fileURLWithPath: "/tmp/apple-tasks-layout-test-home")
        let layout = AppleTasksLayout.resolve(env: [:], home: home)
        XCTAssertEqual(layout.config.path, home.appendingPathComponent(".config/apple-tasks").path)
        XCTAssertTrue(layout.runs.path.hasSuffix("Library/Application Support/apple-tasks/runs"))
        XCTAssertTrue(layout.scratch.path.hasSuffix("Library/Application Support/apple-tasks/scratch"))
        XCTAssertTrue(layout.worktrees.path.hasSuffix("Library/Application Support/apple-tasks/worktrees"))
        XCTAssertFalse(layout.runs.path.contains(".config/apple-tasks"))
        XCTAssertFalse(layout.scratch.path.contains(".config/apple-tasks"))
        XCTAssertFalse(layout.worktrees.path.contains(".config/apple-tasks"))

        let injected = AppleTasksLayout.resolve(
            env: ["APPLE_TASKS_SUPPORT_DIR": "/tmp/support-root",
                  "APPLE_TASKS_CONFIG_DIR": "/tmp/config-root"],
            home: home)
        XCTAssertEqual(injected.config.path, "/tmp/config-root")
        XCTAssertEqual(injected.runs.path, "/tmp/support-root/runs")
        XCTAssertEqual(injected.scratch.path, "/tmp/support-root/scratch")
        XCTAssertEqual(injected.worktrees.path, "/tmp/support-root/worktrees")
        XCTAssertEqual(injected.scratchDir(4).path, "/tmp/support-root/scratch/4")
        XCTAssertEqual(injected.worktreeDir(4).path, "/tmp/support-root/worktrees/4")

        let passkeys = GatehouseClient.passkeyURLs(env: [:], home: home)
        XCTAssertFalse(passkeys.isEmpty)
        XCTAssertTrue(passkeys.allSatisfy { $0.path.hasPrefix(home.path + "/") })
    }

    func testMigrationMovesRuntimeDirsAndRepairsKnownGitDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-layout-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let wt = config.appendingPathComponent("worktrees/7", isDirectory: true)
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/not-a-repo/.git/worktrees/agent-7\n".utf8)
            .write(to: wt.appendingPathComponent(".git"))
        try fm.createDirectory(at: config.appendingPathComponent("scratch/7"), withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: config.appendingPathComponent("scratch/7/note.txt"))
        try fm.createDirectory(at: config.appendingPathComponent("runs"), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: config.appendingPathComponent("runs/7.log"))
        try Data("{\"agents\":{}}".utf8).write(to: config.appendingPathComponent("agents.json"))

        var repairs: [(String, [String])] = []
        var rewrites: [(String, String)] = []
        let result = AppleTasksLayout.migrateRuntime(
            from: config, to: support, busy: { false },
            rewriteLedger: { rewrites.append(($0, $1)); return 1 }
        ) { gitDir, trees in
            repairs.append((gitDir, trees))
            return 0
        }
        XCTAssertEqual(Set(result.moved), Set(["worktrees", "scratch", "runs"]))
        XCTAssertEqual(rewrites.map(\.0), ["worktrees", "scratch", "runs"].map {
            config.appendingPathComponent($0, isDirectory: true).path + "/"
        })
        XCTAssertEqual(rewrites.map(\.1), ["worktrees", "scratch", "runs"].map {
            support.appendingPathComponent($0, isDirectory: true).path + "/"
        })
        XCTAssertEqual(result.ledgerRowsRewritten, 3)
        XCTAssertEqual(repairs.map(\.0), ["/tmp/not-a-repo/.git"])
        let repaired = repairs.first?.1.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        XCTAssertEqual(repaired, [support.appendingPathComponent("worktrees/7").standardizedFileURL.path])
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("runs/7.log")), "log")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("scratch/7/note.txt")), "scratch")
        XCTAssertTrue(fm.fileExists(atPath: config.appendingPathComponent("agents.json").path))
        XCTAssertFalse(fm.fileExists(atPath: config.appendingPathComponent("runs").path))
        XCTAssertFalse(fm.fileExists(atPath: config.appendingPathComponent("worktrees").path))
        XCTAssertFalse(fm.fileExists(atPath: config.appendingPathComponent("scratch").path))

        let again = AppleTasksLayout.migrateRuntime(
            from: config, to: support, busy: { false }, rewriteLedger: { _, _ in 0 }
        ) { _, _ in
            XCTFail("second migration must not repair")
            return 1
        }
        XCTAssertTrue(again.moved.isEmpty)
        XCTAssertTrue(again.repairedGitDirs.isEmpty)
    }

    func testMigrationDefersWhileADispatchIsRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-layout-busy-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: config.appendingPathComponent("worktrees/9"), withIntermediateDirectories: true)
        let result = AppleTasksLayout.migrateRuntime(
            from: config, to: support, busy: { true },
            rewriteLedger: { _, _ in XCTFail("no rewrite while busy"); return 0 }
        ) { _, _ in
            XCTFail("no repair while busy")
            return 1
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: config.appendingPathComponent("worktrees/9").path))
    }

    func testMainGitDirFromRelativeFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-gitdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = root.appendingPathComponent("worktrees/1", isDirectory: true)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try Data("gitdir: ../../demo/.git/worktrees/agent-1\n".utf8)
            .write(to: wt.appendingPathComponent(".git"))
        let gitDir = AppleTasksLayout.mainGitDir(worktree: wt)
        XCTAssertEqual(gitDir, root.appendingPathComponent("demo/.git").standardizedFileURL.path)
    }

    // MARK: pipes

    func testPostExitDrainDoesNotBlockWhenWriteEndStaysOpen() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let box = PipeBox()
        let stop = PipeStop()
        let group = DispatchGroup()
        PipeDrain.copy(pipe.fileHandleForReading, stop: stop, group: group) { box.add($0) }
        try writer.write(contentsOf: Data("hello\n".utf8))
        let saw = Date()
        while box.snapshot.isEmpty && Date().timeIntervalSince(saw) < 2 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(box.snapshot, Data("hello\n".utf8))
        let start = Date()
        XCTAssertFalse(PipeDrain.finish(group, stop: stop, timeout: 0.4))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try writer.close()
    }

    func testDrainFinishesOnEOF() throws {
        let pipe = Pipe()
        let box = PipeBox()
        let stop = PipeStop()
        let group = DispatchGroup()
        PipeDrain.copy(pipe.fileHandleForReading, stop: stop, group: group) { box.add($0) }
        try pipe.fileHandleForWriting.write(contentsOf: Data("bye".utf8))
        try pipe.fileHandleForWriting.close()
        let start = Date()
        XCTAssertTrue(PipeDrain.finish(group, stop: stop, timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(box.snapshot, Data("bye".utf8))
    }

    func testCursorFilterStillReadsPipedChunks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-ndjson-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("run.log")
        guard let handle = RunLogs.create(at: logURL.path) else {
            XCTFail("could not create log")
            return
        }
        let filter = CursorNDJSONFilter(log: handle)
        let pipe = Pipe()
        let stop = PipeStop()
        let group = DispatchGroup()
        PipeDrain.copy(pipe.fileHandleForReading, stop: stop, group: group) { filter.ingest($0) }
        let line = "{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"gpt-test\",\"session_id\":\"sess-1\"}\n"
        try pipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(PipeDrain.finish(group, stop: stop, timeout: 2))
        filter.flush()
        try handle.close()
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("model=gpt-test"))
        XCTAssertTrue(text.contains("session=sess-1"))
        XCTAssertEqual(filter.resolvedModel, "gpt-test")
        XCTAssertEqual(filter.sessionId, "sess-1")
    }

    // MARK: doctor and approvals

    func testDoctorJSONGainsGatehouseFields() throws {
        _ = \DoctorOut.gatehouse
        let json = """
        {"agents": {
          "cursor": {"command": ["agent"], "sandbox": {"mode": "Gatehouse", "net": "outbound", "preset": "cursor"}},
          "claude": {"command": ["claude"]},
          "hermes": {"command": ["hermes"], "sandbox": {"mode": "off"}}
        }}
        """
        let config = try JSONDecoder().decode(AgentsConfig.self, from: Data(json.utf8))
        let absent = GatehouseProbeFacts()
        let missing = GatehouseClient.doctorStatus(agents: config.agents, facts: absent)
        XCTAssertFalse(missing.running)
        XCTAssertFalse(missing.passkeyEnrolled)
        XCTAssertFalse(missing.hooksFailClosed)
        XCTAssertEqual(missing.unsandboxedLanes, ["claude", "hermes"])
        XCTAssertTrue(missing.note.contains("not detected"))
        let data = try JSONEncoder().encode(missing)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["running"] as? Bool, false)
        XCTAssertEqual(obj["passkeyEnrolled"] as? Bool, false)
        XCTAssertEqual(obj["hooksFailClosed"] as? Bool, false)
        XCTAssertEqual(obj["unsandboxedLanes"] as? [String], ["claude", "hermes"])

        let live = GatehouseProbeFacts(
            statusCode: 0,
            statusStdout: "gatehoused up 3s (protocol v1)\npending approvals: 0\n",
            passkeyJSON: [Data("[{}]".utf8)],
            hooksText: "fail_closed = true\n",
            ctlSocketExists: false)
        // No host policy rule yet: a plain "ask" is not a strong approval.
        XCTAssertFalse(GatehouseClient.delegatesApprovals(live))
        var withPolicy = live
        withPolicy.policyText = try String(
            contentsOf: repoRoot().appendingPathComponent("examples/gatehouse/apple-tasks-policy.toml"),
            encoding: .utf8)
        XCTAssertTrue(GatehouseClient.delegatesApprovals(withPolicy))
        var weakPolicy = live
        weakPolicy.policyText = "[[rules]]\ntier = \"ask\"\nargs_glob = [\"__approve_strong *\"]\n"
        XCTAssertFalse(GatehouseClient.delegatesApprovals(weakPolicy))
        let ready = GatehouseClient.doctorStatus(agents: config.agents, facts: live)
        XCTAssertTrue(ready.running)
        XCTAssertTrue(ready.passkeyEnrolled)
        XCTAssertTrue(ready.hooksFailClosed)
        XCTAssertEqual(ready.unsandboxedLanes, ["claude", "hermes"])

        let emptyKeys = GatehouseProbeFacts(passkeyJSON: [Data("[]".utf8)], ctlSocketExists: true)
        XCTAssertTrue(GatehouseClient.daemonRunning(emptyKeys))
        XCTAssertFalse(GatehouseClient.passkeyEnrolled(emptyKeys))
        XCTAssertFalse(GatehouseClient.delegatesApprovals(emptyKeys))
        XCTAssertFalse(GatehouseClient.hooksFailClosed(
            GatehouseProbeFacts(hooksText: "fail_closed = false\n")))
    }

    func testAskInterpretationDoesNotRequireTheBinary() {
        XCTAssertEqual(GatehouseClient.interpretAsk(code: 0, timedOut: false), "approved")
        XCTAssertEqual(GatehouseClient.interpretAsk(code: 2, timedOut: false), "denied")
        XCTAssertNil(GatehouseClient.interpretAsk(code: 0, timedOut: true))
        XCTAssertNil(GatehouseClient.interpretAsk(code: 127, timedOut: false))
        let absent = GatehouseProbeFacts(statusCode: 127, statusStdout: "no such file")
        XCTAssertFalse(GatehouseClient.delegatesApprovals(absent))
    }

    // MARK: shipped files

    func testPolicyFragmentMatchesAllowAndDenyLists() throws {
        let url = repoRoot().appendingPathComponent("examples/gatehouse/apple-tasks-policy.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("default_tier = \"ask\""))
        XCTAssertTrue(text.contains("tier = \"allow\""))
        XCTAssertTrue(text.contains("tier = \"deny\""))
        XCTAssertTrue(text.contains("tier = \"ask_strong\""))
        for allow in ["update *", "complete *", "notes create*", "notify*", "approve request*", "approve check*"] {
            XCTAssertTrue(text.contains("\"\(allow)\""), allow)
        }
        for deny in ["secret*", "approve answer*", "dispatch-retry*", "serve*",
                     "dispatch-accept*", "dispatch-discard*", "dispatch-cancel*",
                     "dispatch-pause*", "dispatch-resume*"] {
            XCTAssertTrue(text.contains("\"\(deny)\""), deny)
        }
        XCTAssertTrue(text.contains("\"dispatch\""))
        XCTAssertTrue(text.contains("\"dispatch *\""))
        XCTAssertTrue(text.contains("__approve_strong"))
    }

    func testExamplesKeepUnsandboxedCursorAndOptionalGatehouseLane() throws {
        let stock = try JSONDecoder().decode(
            AgentsConfig.self, from: Data(contentsOf: repoRoot().appendingPathComponent("examples/agents.json")))
        XCTAssertNil(stock.agents["cursor"]?.sandbox)
        XCTAssertEqual(stock.agents["cursor"]?.command?.contains("--sandbox"), true)
        XCTAssertEqual(stock.agents["cursor"]?.command?.contains("disabled"), true)

        let optional = try JSONDecoder().decode(
            AgentsConfig.self,
            from: Data(contentsOf: repoRoot().appendingPathComponent("examples/agents.gatehouse.json")))
        let lane = try XCTUnwrap(optional.agents["cursor"])
        XCTAssertEqual(lane.sandbox, sandbox())
        XCTAssertNotEqual(lane.command?.contains("--sandbox"), true)
        let planned = Dispatch.planArgv(
            argv: lane.command ?? [], sandbox: lane.sandbox,
            workspace: "/wt", repo: "/repo", envPassthrough: lane.envPassthrough ?? [])
        XCTAssertEqual(planned.first, "gate")
        XCTAssertTrue(planned.contains("--workspace"))
        XCTAssertTrue(planned.contains("/repo/.git"))
        XCTAssertTrue(planned.contains("CURSOR_API_KEY"))
        XCTAssertFalse(planned.contains("--sandbox"))
    }
}

private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
