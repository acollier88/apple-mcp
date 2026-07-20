import AppKit
import Contacts
import CoreLocation
import EventKit
import Speech
import SwiftUI

/// Privacy grants for THIS app process (TCC is per-host). Settings lets the
/// user prompt for each one instead of waiting for a silent CLI failure.
struct PermissionsSettingsTab: View {
    @State private var rows: [PermissionRow] = PermissionProbe.snapshot()
    @State private var isPrompting = false
    @State private var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions are granted per app. Prompting here attributes grants to AgentTasks (not Terminal or your MCP host). Automation for Notes/Mail is prompted the first time those CLI commands run.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLI binary")
                            .font(.body.weight(.medium))
                        Text(CLI.displayBinaryPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Override with APPLE_TASKS_BIN, or rebuild the app after make.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)

                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.body.weight(.medium))
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(row.statusLabel)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(row.statusColor)
                                .background(row.statusColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 4)
                    }

                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Settings")
                    .font(.headline)
                Text("Permissions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPrompting {
                ProgressView().controlSize(.small)
            }
            Button("Prompt for Permissions") {
                Task { await promptAll() }
            }
            .disabled(isPrompting)
            .help("Request Reminders, Calendars, Contacts, Location, and Speech for this app")

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh status")

            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Open Privacy & Security in System Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func refresh() {
        rows = PermissionProbe.snapshot()
    }

    private func promptAll() async {
        guard !isPrompting else { return }
        isPrompting = true
        caption = "Requesting…"
        await PermissionProbe.requestAll()
        refresh()
        let denied = rows.filter { $0.kind == .denied }.map(\.title)
        await MainActor.run {
            isPrompting = false
            if denied.isEmpty {
                caption = "Prompts finished. If something still says Not determined, try again after unlocking the Mac."
            } else {
                caption = "Denied (use System Settings to re-enable): \(denied.joined(separator: ", "))"
            }
        }
    }
}

struct PermissionRow: Identifiable {
    enum Kind { case granted, denied, notDetermined, restricted, unknown }
    let id: String
    let title: String
    let detail: String
    let statusLabel: String
    let kind: Kind

    var statusColor: Color {
        switch kind {
        case .granted: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        case .unknown: return .secondary
        }
    }
}

enum PermissionProbe {
    static func snapshot() -> [PermissionRow] {
        [
            remindersRow(),
            calendarsRow(),
            contactsRow(),
            locationRow(),
            speechRow(),
        ]
    }

    static func requestAll() async {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToReminders()
        _ = try? await store.requestFullAccessToEvents()

        let contacts = CNContactStore()
        _ = try? await contacts.requestAccess(for: .contacts)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                cont.resume()
            }
        }

        await LocationPermissionRequester.request()
    }

    private static func remindersRow() -> PermissionRow {
        mapEK(title: "Reminders", detail: "Task queue (plans & agent work)",
              status: EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func calendarsRow() -> PermissionRow {
        mapEK(title: "Calendars", detail: "Events & time-blocking",
              status: EKEventStore.authorizationStatus(for: .event))
    }

    private static func contactsRow() -> PermissionRow {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let (label, kind): (String, PermissionRow.Kind) = {
            switch status {
            case .authorized: return ("Granted", .granted)
            case .denied: return ("Denied", .denied)
            case .restricted: return ("Restricted", .restricted)
            case .notDetermined: return ("Not determined", .notDetermined)
            case .limited: return ("Limited", .granted)
            @unknown default: return ("Unknown", .unknown)
            }
        }()
        return PermissionRow(id: "contacts", title: "Contacts",
                             detail: "Read-only people lookup", statusLabel: label, kind: kind)
    }

    private static func locationRow() -> PermissionRow {
        let status = CLLocationManager().authorizationStatus
        let (label, kind): (String, PermissionRow.Kind) = {
            switch status {
            case .authorizedAlways, .authorizedWhenInUse: return ("Granted", .granted)
            case .denied: return ("Denied", .denied)
            case .restricted: return ("Restricted", .restricted)
            case .notDetermined: return ("Not determined", .notDetermined)
            @unknown default: return ("Unknown", .unknown)
            }
        }()
        return PermissionRow(id: "location", title: "Location",
                             detail: "whereami / context gates", statusLabel: label, kind: kind)
    }

    private static func speechRow() -> PermissionRow {
        let status = SFSpeechRecognizer.authorizationStatus()
        let (label, kind): (String, PermissionRow.Kind) = {
            switch status {
            case .authorized: return ("Granted", .granted)
            case .denied: return ("Denied", .denied)
            case .restricted: return ("Restricted", .restricted)
            case .notDetermined: return ("Not determined", .notDetermined)
            @unknown default: return ("Unknown", .unknown)
            }
        }()
        return PermissionRow(id: "speech", title: "Speech Recognition",
                             detail: "Voice-note transcription", statusLabel: label, kind: kind)
    }

    private static func mapEK(title: String, detail: String, status: EKAuthorizationStatus) -> PermissionRow {
        let (label, kind): (String, PermissionRow.Kind) = {
            switch status {
            case .fullAccess: return ("Granted", .granted)
            case .writeOnly: return ("Write only", .granted)
            case .denied: return ("Denied", .denied)
            case .restricted: return ("Restricted", .restricted)
            case .notDetermined: return ("Not determined", .notDetermined)
            @unknown default: return ("Unknown", .unknown)
            }
        }()
        return PermissionRow(id: title.lowercased(), title: title, detail: detail,
                             statusLabel: label, kind: kind)
    }
}

/// Keeps a CLLocationManager alive across the async authorization callback.
@MainActor
final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionRequester()
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Void, Never>?

    static func request() async {
        await shared.request()
    }

    private func request() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation?.resume()
            continuation = cont
            let manager = CLLocationManager()
            self.manager = manager
            manager.delegate = self
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            default:
                finish()
            }
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
        manager?.delegate = nil
        manager = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus != .notDetermined {
                finish()
            }
        }
    }
}
