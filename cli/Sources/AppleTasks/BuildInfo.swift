import Foundation
import MachO

/// Build provenance stamped by `make cli` (#33). cli/Makefile writes
/// `commit=<sha>[-dirty]` / `source=<repo root>` lines to a file under
/// .build/stamp/ and links it into the `__TEXT,__at_build` section. Nothing
/// tracked is generated, so a plain `swift build` / `swift test` (CI) still
/// builds — it just has no section and reports "unknown".
enum BuildInfo {
    static let version = "0.1.0"
    static let segment = "__TEXT"
    static let section = "__at_build"

    /// Short commit the binary was built from, "-dirty" when cli/ had
    /// uncommitted changes, or "unknown" for an unstamped build.
    static var commit: String { fields["commit"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown" }

    /// Repo root the stamped build came from (nil when unstamped).
    static var sourceRoot: String? { fields["source"].flatMap { $0.isEmpty ? nil : $0 } }

    /// What `apple-tasks --version` prints.
    static var versionString: String { "\(version) (commit \(commit))" }

    /// Commit from `apple-tasks --version` output; nil for "unknown" or an
    /// older binary that predates stamping ("0.1.0").
    static func commit(fromVersionOutput output: String) -> String? {
        guard let range = output.range(of: #"\(commit ([^)\s]+)\)"#, options: .regularExpression) else {
            return nil
        }
        let value = output[range].dropFirst("(commit ".count).dropLast()
        return value == "unknown" ? nil : String(value)
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static let fields: [String: String] = {
        // Image 0 is the main executable (under XCTest that is the runner,
        // which has no section → "unknown").
        guard let header = _dyld_get_image_header(0) else { return [:] }
        var size: UInt = 0
        let raw = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(raw, segment, section, &size), size > 0 else { return [:] }
        let data = Data(bytes: bytes, count: Int(size))
        return parse(String(decoding: data, as: UTF8.self))
    }()
}
