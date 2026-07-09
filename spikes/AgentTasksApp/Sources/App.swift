import CoreLocation
import SwiftUI
import Foundation
import EventKit
import Combine

@main
struct AgentTasksApp: App {
    init() {
        // Headless helper mode: bare CLI executables can't get a Location
        // Services grant on recent macOS, but this app bundle can — so
        // apple-tasks shells out to `AgentTasks --whereami` for the fix.
        if CommandLine.arguments.contains("--whereami") {
            WhereamiMode.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
                .task {
                    AgentTasksShortcuts.updateAppShortcutParameters()
                    if #available(macOS 27.0, *) {
                        await SpotlightDonation.donateOpenTasks()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    if #available(macOS 27.0, *) {
                        Task {
                            await SpotlightDonation.donateAllOpenTasks()
                        }
                    }
                }
        }
    }
}

// MARK: - Models & Helpers

struct AuditEvent: Codable, Identifiable {
    var id = UUID()
    let ts: String
    let caller: String
    let command: String
    let taskId: String?
    let list: String?
    let detail: String?
    let result: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ts, caller, command, taskId, list, detail, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ts = (try? container.decode(String.self, forKey: .ts)) ?? ""
        self.caller = (try? container.decode(String.self, forKey: .caller)) ?? "unknown"
        self.command = (try? container.decode(String.self, forKey: .command)) ?? ""
        self.taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        self.list = try container.decodeIfPresent(String.self, forKey: .list)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.result = (try? container.decode(String.self, forKey: .result)) ?? "ok"
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.id = UUID()
    }
}

func relativeTime(from isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    var date = formatter.date(from: isoString)
    if date == nil {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = fractionalFormatter.date(from: isoString)
    }
    
    guard let date = date else { return isoString }
    let diff = Date().timeIntervalSince(date)
    if diff < 0 {
        return "now"
    }
    let seconds = Int(diff)
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m ago"
    }
    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)h ago"
    }
    let days = hours / 24
    return "\(days)d ago"
}

// MARK: - Views

struct ContentView: View {
    @State private var events: [AuditEvent] = []
    @State private var isLoading = false
    @State private var isTriaging = false
    @State private var triageResult: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text("AgentTasks")
                        .font(.headline)
                    Text("Activity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()

                if let triageResult {
                    Text(triageResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button {
                    Task { await triage() }
                } label: {
                    HStack(spacing: 5) {
                        if isTriaging {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        Text("Triage Inbox")
                    }
                }
                .disabled(isTriaging)
                .help("Classify and route untagged reminders in your inbox")

                RefreshButton(isLoading: isLoading) {
                    Task {
                        await refresh()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            if events.isEmpty {
                // Current hero content as empty state when the log is empty or CLI is missing/errored
                VStack(spacing: 15) {
                    Spacer()
                    Image(systemName: "checklist")
                        .font(.system(size: 40))
                    Text("AgentTasks")
                        .font(.title2.bold())
                    Text("Exposes the agent task queue to Siri, Shortcuts, and Spotlight via App Intents. Nothing to configure here — try \"Check agent tasks\" in Shortcuts or Siri.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .onAppear {
            Task {
                await refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refresh()
            }
        }
    }
    
    private func triage() async {
        guard !isTriaging else { return }
        isTriaging = true
        triageResult = nil
        let summary: String = await Task.detached {
            do {
                let json = try CLI.run(["triage", "--apply"])
                let data = Data(json.utf8)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let actions = obj["actions"] as? [[String: Any]] else { return "Triage done" }
                if actions.isEmpty { return "Inbox clear — nothing to triage" }
                let agents = actions.filter { ($0["kind"] as? String) == "agent" }.count
                let personal = actions.filter { ($0["kind"] as? String) == "personal" }.count
                return "Triaged \(actions.count): \(agents) agent, \(personal) personal"
            } catch {
                return "Triage failed"
            }
        }.value
        await MainActor.run {
            self.triageResult = summary
            self.isTriaging = false
        }
        await refresh() // show the new triage audit rows in the feed
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let jsonString = try await Task.detached {
                try CLI.run(["log", "--limit", "30"])
            }.value
            
            let data = Data(jsonString.utf8)
            let decoded = try JSONDecoder().decode([AuditEvent].self, from: data)
            
            await MainActor.run {
                self.events = decoded
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.events = []
                self.isLoading = false
            }
        }
    }
}

struct RefreshButton: View {
    let isLoading: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.blue : Color.secondary)
                .rotationEffect(.degrees(isLoading ? 360 : 0))
                .animation(isLoading ? Animation.linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: isLoading)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Refresh")
    }
}

struct EventRow: View {
    let event: AuditEvent
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Time relative
                Text(relativeTime(from: event.ts))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .leading)
                
                // Caller Badge
                BadgeView(caller: event.caller)
                
                // Command
                Text(event.command)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(event.result == "ok" ? Color.primary : Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(event.result == "ok" ? Color.primary.opacity(0.05) : Color.red.opacity(0.1))
                    .cornerRadius(4)
                
                // Detail
                Text(event.detail ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(event.result == "ok" ? Color.primary : Color.red)
                
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            
            Divider()
                .opacity(0.4)
        }
        .background(
            event.result == "ok" 
                ? (isHovered ? Color.primary.opacity(0.02) : Color.clear)
                : (isHovered ? Color.red.opacity(0.06) : Color.red.opacity(0.03))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct BadgeView: View {
    let caller: String
    
    var body: some View {
        let badge = callerBadge(for: caller)
        let colors = badgeColors(for: badge)
        
        Text(badge)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(colors.text)
            .background(colors.bg)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(colors.border, lineWidth: 1)
            )
    }
    
    private func callerBadge(for caller: String) -> String {
        let c = caller.lowercased()
        if c.contains("agent:claude") { return "agent:claude" }
        if c.contains("agent:antigravity") { return "agent:antigravity" }
        if c.contains("mcp") { return "mcp" }
        if c.contains("app") { return "app" }
        if c.contains("zsh") { return "zsh" }
        if c.contains("bash") { return "bash" }
        if c.contains("sh") { return "sh" }
        return caller
    }
    
    private func badgeColors(for badge: String) -> (text: Color, bg: Color, border: Color) {
        if badge.starts(with: "agent:") {
            return (
                Color.orange,
                Color.orange.opacity(0.1),
                Color.orange.opacity(0.3)
            )
        }
        switch badge {
        case "mcp":
            return (
                Color.indigo,
                Color.indigo.opacity(0.1),
                Color.indigo.opacity(0.3)
            )
        case "app":
            return (
                Color.blue,
                Color.blue.opacity(0.1),
                Color.blue.opacity(0.3)
            )
        default:
            return (
                Color.secondary,
                Color.secondary.opacity(0.1),
                Color.secondary.opacity(0.3)
            )
        }
    }
}

// MARK: - Legacy Whereami Mode

enum WhereamiMode {
    static func runAndExit() -> Never {
        let timeout: TimeInterval
        if let index = CommandLine.arguments.firstIndex(of: "--timeout"),
           let value = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) {
            timeout = value
        } else {
            timeout = 20
        }

        let fetcher = AppLocationFetcher()
        switch fetcher.fetchSync(timeout: timeout) {
        case .success(let location):
            let json = """
            {"latitude": \(location.coordinate.latitude), \
            "longitude": \(location.coordinate.longitude), \
            "accuracyMeters": \(location.horizontalAccuracy), \
            "timestamp": "\(ISO8601DateFormatter().string(from: location.timestamp))"}
            """
            print(json)
            exit(0)
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

final class AppLocationFetcher: NSObject, CLLocationManagerDelegate {
    private var result: Result<CLLocation, Error>?

    private func fail(_ message: String) {
        result = .failure(NSError(domain: "AgentTasks", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]))
    }

    func fetchSync(timeout: TimeInterval) -> Result<CLLocation, Error> {
        guard CLLocationManager.locationServicesEnabled() else {
            fail("Location Services is off system-wide.")
            return result!
        }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.startUpdatingLocation()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        manager.stopUpdatingLocation()
        if result == nil {
            // locationd doesn't always deliver a live callback promptly; its
            // cached fix (≤10 min old) beats failing for "am I home?" checks.
            if let cached = manager.location,
               Date().timeIntervalSince(cached.timestamp) < 600 {
                result = .success(cached)
            } else {
                fail("timed out after \(Int(timeout))s (authorization: \(manager.authorizationStatus.rawValue)). " +
                     "Enable AgentTasks in System Settings > Privacy & Security > Location Services.")
            }
        }
        return result!
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            fail("Location Services access denied for AgentTasks. " +
                 "Enable it in System Settings > Privacy & Security > Location Services.")
        default:
            break // .notDetermined — waiting on the user prompt
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            result = .success(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        result = .failure(error)
    }
}
