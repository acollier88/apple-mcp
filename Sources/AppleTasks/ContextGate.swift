import CoreLocation
import Foundation

// IDEAS #22: context-gated dispatch. Per-agent `conditions` in agents.json
// (location / power / maxLoad) are checked before a task is claimed; a task
// that fails a gate stays queued untouched — no ledger row, no [dispatched]
// or [failed] tag — and is simply reconsidered on the next pass. All checks
// are reads; nothing here needs new permissions.

/// Per-run cache for gate probes, so N candidate tasks cost at most one
/// pmset call and one location fix per dispatch pass.
final class GateContext {
    private var cachedPower: String??       // .some(nil) = probe failed
    private var cachedLocation: CLLocation??

    /// "ac" | "battery", or nil when pmset output is unrecognizable.
    func powerSource() -> String? {
        if let cachedPower { return cachedPower }
        let result: String?
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            if out.contains("AC Power") { result = "ac" }
            else if out.contains("Battery Power") { result = "battery" }
            else { result = nil }
        } else {
            result = nil
        }
        cachedPower = result
        return result
    }

    private var locationError: String?

    /// One-shot location fix (whereami plumbing, app-helper fallback included).
    func currentLocation() async -> CLLocation? {
        if let cachedLocation { return cachedLocation }
        do {
            let fix = try await LocationFetcher.fetch(timeout: 30)
            cachedLocation = .some(fix)
            return fix
        } catch {
            locationError = "\(error)"
            cachedLocation = .some(nil)
            return nil
        }
    }

    /// nil = all gates pass; otherwise a human-readable reason the task
    /// stays queued. Cheap checks run first; the location fix is only
    /// attempted when a location condition exists.
    func gateReason(_ conditions: AgentsConfig.Conditions, config: AgentsConfig) async -> String? {
        if let maxLoad = conditions.maxLoad {
            var loads = [0.0, 0.0, 0.0]
            getloadavg(&loads, 3)
            if loads[0] > maxLoad {
                return String(format: "load %.1f > max %.1f", loads[0], maxLoad)
            }
        }
        if let power = conditions.power?.lowercased() {
            guard let source = powerSource() else { return "power source unknown" }
            if source != power { return "on \(source) power (needs \(power))" }
        }
        if let placeName = conditions.location {
            guard let place = config.places?[placeName] else {
                return "unknown place '\(placeName)' (add it to places in agents.json)"
            }
            guard let here = await currentLocation() else {
                return "location unavailable" + (locationError.map { " (\($0))" } ?? "")
            }
            let distance = here.distance(from: CLLocation(latitude: place.lat, longitude: place.lon))
            let radius = place.radiusM ?? 150
            if distance > radius {
                return String(format: "%.0fm from '%@' (radius %.0fm)", distance, placeName, radius)
            }
        }
        return nil
    }
}
