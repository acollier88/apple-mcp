import ArgumentParser
import Foundation

// IDEAS #23: iCloud Drive drop-folder capture — the universal capture escape
// hatch. A watched folder (default the iCloud "AgentInbox") where ANY device
// can drop .txt/.md files (share sheet, Files app, Scriptable, laptop);
// `apple-tasks files scan` emits {file, ts, content} for the triage agent to
// convert into tagged tasks. On --archive, processed files move to a done/
// subfolder so they aren't re-emitted (belt-and-suspenders with the
// watermark). Best for long pasted content, forwarded text, code snippets —
// anything awkward to say to Siri.

struct FileDropOut: Codable {
    let file: String
    let modified: String
    let content: String
    var archivedTo: String?
}

struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture text/markdown files dropped in the iCloud inbox folder.",
        subcommands: [FilesScan.self],
        defaultSubcommand: FilesScan.self
    )

    /// Default drop folder in iCloud Drive.
    static var defaultDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/AgentInbox").path
    }
}

struct FilesScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        Read .txt/.md files modified since a watermark and emit their content. \
        Without --since, uses (and advances) the stored watermark; first run \
        looks back 24h. --archive moves processed files into a done/ subfolder.
        """
    )

    @Option(help: "Folder to scan (default: iCloud Drive/AgentInbox).")
    var dir: String?

    @Option(help: "Override watermark: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Stateless (does not advance the stored watermark).")
    var since: String?

    @Option(name: .customLong("max-chars"), help: "Truncate each file's content (default 8000).")
    var maxChars: Int = 8000

    @Flag(help: "Move processed files into a done/ subfolder (skips files already there).")
    var archive = false

    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "text"]
    private static let doneSubdir = "done"

    func run() async throws {
        let scanStart = Date()
        let folder = dir.map { NSString(string: $0).expandingTildeInPath } ?? Files.defaultDir
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)

        let sinceDate: Date
        var advanceWatermark = false
        if let since {
            sinceDate = try Dates.parseDateTime(since).date
        } else {
            advanceWatermark = true
            if let watermark = ScanState.load().filesScanWatermark,
               let parsed = ISO8601DateFormatter().date(from: watermark) {
                sinceDate = parsed
            } else {
                sinceDate = scanStart.addingTimeInterval(-86_400)
            }
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        let isoOut = ISO8601DateFormatter()
        var results: [FileDropOut] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.textExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified > sinceDate else { continue }

            // iCloud placeholders (.icloud) download on read; a plain read of
            // a not-yet-downloaded file returns empty, so request materialization.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

            var out = FileDropOut(file: url.path, modified: isoOut.string(from: modified),
                                  content: String(content.prefix(maxChars)), archivedTo: nil)
            if archive {
                out.archivedTo = try Self.archiveFile(url, in: folderURL)
            }
            results.append(out)
        }

        if advanceWatermark {
            var state = ScanState.load()
            state.filesScanWatermark = isoOut.string(from: scanStart)
            try state.save()
        }
        emit(results)
    }

    /// Move a processed file into <folder>/done/, disambiguating name clashes.
    static func archiveFile(_ url: URL, in folder: URL) throws -> String {
        let doneDir = folder.appendingPathComponent(doneSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: doneDir, withIntermediateDirectories: true)
        var target = doneDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = String(Int(Date().timeIntervalSince1970))
            let base = url.deletingPathExtension().lastPathComponent
            target = doneDir.appendingPathComponent("\(base)-\(stamp).\(url.pathExtension)")
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target.path
    }
}
