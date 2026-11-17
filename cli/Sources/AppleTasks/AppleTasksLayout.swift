import Foundation

/// Where apple-tasks keeps files.
///
/// Config, the ledger, `agents.json`, and secrets stay in `~/.config/apple-tasks`
/// so a sandbox can deny that directory. Worktrees, scratch dirs, and run logs
/// live under `~/Library/Application Support/apple-tasks` — outside the config
/// dir, and the workspace a sandboxed lane is given.
///
/// Both roots are resolved from explicit home/env values. Tests pass a temp
/// directory; nothing here migrates the real config dir unless a caller asks
/// `migrateRuntime` with those paths.
struct AppleTasksLayout: Equatable {
    var config: URL
    var support: URL

    var runs: URL { support.appendingPathComponent("runs", isDirectory: true) }
    var scratch: URL { support.appendingPathComponent("scratch", isDirectory: true) }
    var worktrees: URL { support.appendingPathComponent("worktrees", isDirectory: true) }

    func scratchDir(_ ledgerId: Int64) -> URL {
        scratch.appendingPathComponent(String(ledgerId), isDirectory: true)
    }

    func worktreeDir(_ ledgerId: Int64) -> URL {
        worktrees.appendingPathComponent(String(ledgerId), isDirectory: true)
    }

    /// `APPLE_TASKS_CONFIG_DIR` / `APPLE_TASKS_SUPPORT_DIR` override the defaults.
    /// `home` is injected so tests never resolve the real user directory.
    static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppleTasksLayout {
        AppleTasksLayout(
            config: directory(
                env["APPLE_TASKS_CONFIG_DIR"],
                default: home.appendingPathComponent(".config/apple-tasks", isDirectory: true)),
            support: directory(
                env["APPLE_TASKS_SUPPORT_DIR"],
                default: home.appendingPathComponent("Library/Application Support/apple-tasks", isDirectory: true)))
    }

    private static func directory(_ override: String?, default fallback: URL) -> URL {
        guard let override, !override.isEmpty else { return fallback }
        let expanded = (override as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}

struct RuntimeMigration: Equatable {
    var moved: [String] = []
    var repairedGitDirs: [String] = []
    var notes: [String] = []
}

extension AppleTasksLayout {
    /// One-time move of `worktrees/`, `scratch/`, and `runs/` out of the config
    /// dir. Config files (agents.json, the ledger, tokens) stay put. When a
    /// moved worktree's `.git` file names a git dir, `repair` runs
    /// `git worktree repair` for it. The default repair shells out to git;
    /// tests pass a closure and a temp pair of directories.
    static func migrateRuntime(
        from configDir: URL,
        to supportDir: URL,
        repair: (_ gitDir: String, _ worktrees: [String]) -> Int32 = liveWorktreeRepair
    ) -> RuntimeMigration {
        let fm = FileManager.default
        var result = RuntimeMigration()
        let names = ["worktrees", "scratch", "runs"]
        let sources = names.filter { isDirectory(configDir.appendingPathComponent($0)) }
        guard !sources.isEmpty else { return result }

        _ = ConfigPermissions.ensurePrivateDirectory(supportDir)
        for name in sources {
            let src = configDir.appendingPathComponent(name, isDirectory: true)
            let dst = supportDir.appendingPathComponent(name, isDirectory: true)
            if moveReplacing(src, to: dst, fileManager: fm, notes: &result.notes) {
                result.moved.append(name)
            }
        }

        let worktreeRoot = supportDir.appendingPathComponent("worktrees", isDirectory: true)
        var byGit: [String: [String]] = [:]
        if let children = try? fm.contentsOfDirectory(at: worktreeRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let gitDir = mainGitDir(worktree: child) else { continue }
                byGit[gitDir, default: []].append(child.path)
            }
        }
        for gitDir in byGit.keys.sorted() {
            let trees = byGit[gitDir] ?? []
            let code = repair(gitDir, trees.sorted())
            if code == 0 {
                result.repairedGitDirs.append(gitDir)
            } else {
                result.notes.append("git worktree repair exited \(code) for \(gitDir)")
            }
        }
        return result
    }

    /// `gitdir:` from a worktree's `.git` file, trimmed to the main git dir
    /// (the path before `/worktrees/`). Nil when the git dir is not known.
    static func mainGitDir(worktree: URL) -> String? {
        let gitFile = worktree.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir)
        guard exists, !isDir.boolValue,
              let text = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.lowercased().hasPrefix("gitdir:")
        }) else { return nil }
        var resolved = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        guard !resolved.isEmpty else { return nil }
        if resolved.hasPrefix("~/") {
            resolved = (resolved as NSString).expandingTildeInPath
        }
        if !resolved.hasPrefix("/") {
            resolved = worktree.appendingPathComponent(resolved).standardizedFileURL.path
        }
        if let range = resolved.range(of: "/worktrees/") {
            resolved = String(resolved[..<range.lowerBound])
        }
        guard resolved.hasSuffix(".git") else { return nil }
        return resolved
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Move `src` onto `dst`. When `dst` already exists, move children that
    /// are not already there, then remove `src` if it is empty.
    private static func moveReplacing(_ src: URL, to dst: URL, fileManager fm: FileManager,
                                      notes: inout [String]) -> Bool {
        if !isDirectory(dst) {
            do {
                try fm.moveItem(at: src, to: dst)
                return true
            } catch {
                do {
                    try fm.copyItem(at: src, to: dst)
                    try fm.removeItem(at: src)
                    return true
                } catch {
                    notes.append("could not move \(src.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
            }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: src.path) else {
            notes.append("could not list \(src.path)")
            return false
        }
        var movedAny = false
        for name in names {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) { continue }
            do {
                try fm.moveItem(at: from, to: to)
                movedAny = true
            } catch {
                notes.append("could not move \(name): \(error.localizedDescription)")
            }
        }
        if (try? fm.contentsOfDirectory(atPath: src.path))?.isEmpty == true {
            try? fm.removeItem(at: src)
        }
        return movedAny
    }

    private static func liveWorktreeRepair(gitDir: String, worktrees: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--git-dir", gitDir, "worktree", "repair"] + worktrees
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
