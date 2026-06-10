import ArgumentParser
import CoreLocation
import Foundation

struct WhereamiOut: Codable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let timestamp: String
    let place: Place?

    struct Place: Codable {
        let name: String?
        let locality: String?
        let administrativeArea: String?
        let postalCode: String?
        let country: String?
    }
}

struct Whereami: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
        One-shot location fix for this Mac (CoreLocation). First run prompts \
        for Location Services access; the grant is per-host-process like \
        Reminders (see doctor).
        """
    )

    @Option(help: "Seconds to wait for a fix before giving up.")
    var timeout: Int = 15

    @Flag(name: .customLong("no-geocode"), help: "Skip reverse geocoding (coordinates only).")
    var noGeocode = false

    func run() async throws {
        let location = try await LocationFetcher.fetch(timeout: TimeInterval(timeout))

        var place: WhereamiOut.Place?
        if !noGeocode {
            // Best-effort: a fix without a place name is still useful offline.
            if let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                place = WhereamiOut.Place(
                    name: mark.name, locality: mark.locality,
                    administrativeArea: mark.administrativeArea,
                    postalCode: mark.postalCode, country: mark.country)
            }
        }

        emit(WhereamiOut(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy,
            timestamp: ISO8601DateFormatter().string(from: location.timestamp),
            place: place))
    }
}

/// CLI CoreLocation needs the classic delegate API driven by a live runloop
/// (the async liveUpdates API never engages TCC for a bare executable).
/// Everything runs on a dedicated thread that pumps its own RunLoop — the
/// proven CoreLocationCLI pattern — bridged back through a continuation.
final class LocationFetcher: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    // All state is touched only on the dedicated fetch thread.
    private var manager: CLLocationManager?
    private var result: Result<CLLocation, Error>?

    static func describeAuthorization() -> String {
        guard CLLocationManager.locationServicesEnabled() else {
            return "Location Services OFF system-wide (System Settings > Privacy & Security)"
        }
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways, .authorizedWhenInUse: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func fetch(timeout: TimeInterval) async throws -> CLLocation {
        let fetcher = LocationFetcher()
        return try await withCheckedThrowingContinuation { cont in
            let thread = Thread {
                cont.resume(with: fetcher.fetchSync(timeout: timeout))
            }
            thread.name = "whereami-location"
            thread.start()
        }
    }

    private func fetchSync(timeout: TimeInterval) -> Result<CLLocation, Error> {
        guard CLLocationManager.locationServicesEnabled() else {
            return .failure(AppleTasksError.automationFailed(
                "Location Services is off system-wide. Enable it in " +
                "System Settings > Privacy & Security > Location Services."))
        }

        let manager = CLLocationManager()
        self.manager = manager
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

        return result ?? .failure(AppleTasksError.automationFailed(
            "timed out after \(Int(timeout))s waiting for a location fix " +
            "(status: \(Self.describeAuthorization())). macOS often adds CLI " +
            "hosts to the Location Services list WITHOUT showing a dialog — " +
            "check System Settings > Privacy & Security > Location Services " +
            "for your terminal/host app and switch it on, then retry."))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            result = .failure(AppleTasksError.automationFailed(
                "Location Services access denied for this host process. " +
                "Grant it in System Settings > Privacy & Security > Location Services."))
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
        // .locationUnknown is transient — CoreLocation keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        result = .failure(error)
    }
}
