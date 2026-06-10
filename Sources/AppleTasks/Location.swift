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

/// Uses the modern async CoreLocation API (macOS 14+): no delegate, no
/// runloop — which a bare CLI doesn't have. liveUpdates() triggers the TCC
/// prompt itself when status is notDetermined.
enum LocationFetcher {
    static func describeAuthorization() -> String {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways, .authorizedWhenInUse: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func fetch(timeout: TimeInterval) async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if #available(macOS 15, *) {
                        if update.authorizationDenied || update.authorizationDeniedGlobally {
                            throw AppleTasksError.automationFailed(
                                "Location Services access denied for this host process. " +
                                "Grant it in System Settings > Privacy & Security > Location Services.")
                        }
                    }
                    if let location = update.location {
                        return location
                    }
                }
                throw AppleTasksError.automationFailed("location updates ended without a fix")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AppleTasksError.automationFailed(
                    "timed out after \(Int(timeout))s waiting for a location fix " +
                    "(status: \(describeAuthorization()))")
            }
            guard let first = try await group.next() else {
                throw AppleTasksError.automationFailed("location fetch failed")
            }
            group.cancelAll()
            return first
        }
    }
}
