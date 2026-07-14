import CoreLocation
import Foundation

// IDEAS #22: context-gated dispatch. Per-agent `conditions` in agents.json
// (location / power / maxLoad / time) are checked before a task is claimed;
// a task that fails a gate stays queued untouched — no ledger row, no
// [dispatched] or [failed] tag — and is simply reconsidered on the next
// pass. All checks are reads; nothing here needs new permissions.

// MARK: - shared time window (IDEAS #43)

/// Local-time window shared by the dispatch `time` gate and notify's
/// `quietHours`: `{"notBetween": ["22:00", "07:00"]}`. Times are HH:mm,
/// 24-hour, local; start > end wraps midnight, so ["22:00", "07:00"]
/// means "blocked overnight". Start == end is an empty window (never in).
struct TimeWindow: Codable {
    let notBetween: [String]

    enum Check {
        /// Now is inside the window; payload is "HH:mm–HH:mm" for reports.
        case inside(String)
        case outside
        /// Unusable config; payload says how to fix it.
        case invalid(String)
    }

    func check(now: Date = Date()) -> Check {
        guard notBetween.count == 2,
              let start = Self.minutesSinceMidnight(notBetween[0]),
              let end = Self.minutesSinceMidnight(notBetween[1]) else {
            return .invalid("notBetween needs [\"HH:mm\", \"HH:mm\"], got \(notBetween)")
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let inside = start <= end
            ? minute >= start && minute < end   // same-day window
            : minute >= start || minute < end   // wraps midnight
        return inside ? .inside("\(notBetween[0])–\(notBetween[1])") : .outside
    }

    private static func minutesSinceMidnight(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

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
        if let time = conditions.time {
            switch time.check() {
            case .inside(let window): return "quiet hours \(window)"
            case .invalid(let why): return "bad time condition: \(why)"
            case .outside: break
            }
        }
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
