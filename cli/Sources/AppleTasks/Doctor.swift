import ArgumentParser
import EventKit
import Foundation
import Speech

struct DoctorOut: Codable {
    let binary: String
    let hostProcess: String
    let reminders: String
    let calendars: String
    let location: String
    let contacts: String
    let foundationModels: String
    let findmySidecar: String
    let mailRule: String
    let dropFolder: String
    let privateHelper: PrivateHelperStatus
    let notesScanWatermark: String?
    let speech: String
    let fullDiskAccess: String
    let agentsConfig: String
    let cursorAgent: String
    let launchAgent: String
    let automationNote: String

    struct PrivateHelperStatus: Codable {
        let present: Bool
        let path: String?
        let check: String?
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report permission and configuration status for THIS host process. TCC grants are per-host: Terminal working proves nothing about an MCP host app."
    )

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func hostProcessName() -> String {
        let ppid = getppid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", "\(ppid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "pid \(ppid)" }
        process.waitUntilExit()
        let name = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "pid \(ppid)" : "\(name) (pid \(ppid))"
    }

    private static func helperStatus() -> DoctorOut.PrivateHelperStatus {
        guard let helper = NativeTags.helperURL else {
            return .init(present: false, path: nil, check: nil)
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--check"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .init(present: true, path: helper.path, check: "ok")
            }
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "failed"
            return .init(present: true, path: helper.path, check: detail)
        } catch {
            return .init(present: true, path: helper.path, check: error.localizedDescription)
        }
    }

    private static func findmyStatus() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/findmy")
        let session = FileManager.default.fileExists(atPath: dir.appendingPathComponent("account.json").path)
        let accessories = ((try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("accessories").path)) ?? [])
            .filter { $0.hasSuffix(".plist") || $0.hasSuffix(".json") }
            .count
        guard session || accessories > 0 else {
            return "not configured (run: tools/findmy/findmy-sidecar.py login)"
        }
        return "session \(session ? "present" : "MISSING"), \(accessories) accessories"
    }

    private static func speechStatus() -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func fdaStatus() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist").path
        if FileManager.default.isReadableFile(atPath: path) {
            return "granted (Safari bookmarks accessible)"
        } else {
            return "denied or not determined (required for Safari Reading List scan; grant in Settings > Privacy > Full Disk Access)"
        }
    }

    private static func agentsConfigStatus() -> String {
        let path = AgentsConfig.url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return "missing (copy examples/agents.json → \(path), or make install-agent)"
        }
        do {
            let cfg = try AgentsConfig.load()
            let tags = cfg.agents.keys.sorted().joined(separator: ", ")
            return "ok (\(cfg.agents.count) agents: \(tags))"
        } catch {
            return "unreadable: \(error.localizedDescription)"
        }
    }

    /// Resolve `agent` (Cursor Agent CLI) on PATH the same way dispatch does (/usr/bin/env).
    private static func cursorAgentStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "agent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return "not found (install: curl https://cursor.com/install -fsS | bash)"
        }
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty else {
            return "not found (install: curl https://cursor.com/install -fsS | bash)"
        }
        return "present: \(path) (tag tasks [cursor][auto]; agent login or CURSOR_API_KEY)"
    }

    private static func launchAgentStatus() -> String {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.apple-tasks.dispatch.plist").path
        guard FileManager.default.fileExists(atPath: plist) else {
            return "not installed (run: make install-agent)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.apple-tasks.dispatch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return "plist present, launchctl probe failed"
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return "loaded (com.apple-tasks.dispatch)"
        }
        return "plist present but not loaded (re-run: make install-agent)"
    }

    func run() async throws {
        emit(DoctorOut(
            binary: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path,
            hostProcess: Self.hostProcessName(),
            reminders: Self.describe(EKEventStore.authorizationStatus(for: .reminder)),
            calendars: Self.describe(EKEventStore.authorizationStatus(for: .event)),
            location: LocationFetcher.describeAuthorization(),
            contacts: ContactsAccess.describeAuthorization(),
            foundationModels: LocalClassifier.status(),
            findmySidecar: Self.findmyStatus(),
            mailRule: FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Scripts/com.apple.mail/apple-tasks-capture.scpt").path)
                ? "installed (attach via Mail > Settings > Rules)"
                : "not installed (run: make mail-rule)",
            dropFolder: FileManager.default.fileExists(atPath: Files.defaultDir)
                ? "present: \(Files.defaultDir)"
                : "not created yet: \(Files.defaultDir)",
            privateHelper: Self.helperStatus(),
            notesScanWatermark: ScanState.load().notesScanWatermark,
            speech: Self.speechStatus(),
            fullDiskAccess: Self.fdaStatus(),
            agentsConfig: Self.agentsConfigStatus(),
            cursorAgent: Self.cursorAgentStatus(),
            launchAgent: Self.launchAgentStatus(),
            automationNote: "Notes/Mail Apple Events permission cannot be probed without triggering a prompt; run 'apple-tasks notes scan --since <now>' to test."
        ))
    }
}
