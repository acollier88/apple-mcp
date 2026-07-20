import CoreLocation
import SwiftUI
import Foundation
import EventKit
import Combine

@main
struct AgentTasksApp: App {
    // EventKit only delivers .EKEventStoreChanged to processes that hold an
    // initialized event store (with access granted), so keep one for the
    // app's lifetime -- without this the observer below never fires.
    private let eventStore = EKEventStore()
    @State private var reindexTask: Task<Void, Never>?

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
                .task {
                    AgentTasksShortcuts.updateAppShortcutParameters()
                    _ = try? await eventStore.requestFullAccessToReminders()
                    if #available(macOS 27.0, *) {
                        await SpotlightDonation.donateOpenTasks()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: nil)) { _ in
                    if #available(macOS 27.0, *) {
                        // Mutations arrive in bursts; debounce before re-donating.
                        reindexTask?.cancel()
                        reindexTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            await SpotlightDonation.donateAllOpenTasks()
                        }
                    }
                }
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
