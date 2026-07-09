import ArgumentParser
import Foundation

// IDEAS #25: Safari Reading List scan. Reads Safari's Bookmarks.plist
// for Reading List entries added since a watermark, emitting {title, url, dateAdded, previewText}
// JSON. Requires Full Disk Access for the host process (e.g. Terminal or MCP host).

struct ReadingListItemOut: Codable {
    let title: String
    let url: String
    let dateAdded: String
    let previewText: String?
}

struct ReadingList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read items from the Safari Reading List.",
        subcommands: [ReadingListScan.self],
        defaultSubcommand: ReadingListScan.self
    )
}

struct ReadingListScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        Scan new items in the Safari Reading List since a watermark. \
        Without --since, uses (and advances) the stored watermark; first run \
        looks back 24h. Requires Full Disk Access.
        """
    )

    @Option(help: "Override watermark: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Stateless (does not advance the stored watermark).")
    var since: String?

    @Option(name: .customLong("max-items"), help: "Limit output to this many items (default 50).")
    var maxItems: Int = 50

    func run() async throws {
        let scanStart = Date()
        let bookmarksPath = (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist").path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: bookmarksPath)

        let sinceDate: Date
        var advanceWatermark = false
        if let since {
            sinceDate = try Dates.parseDateTime(since).date
        } else {
            advanceWatermark = true
            if let watermark = ScanState.load().readingListScanWatermark,
               let parsed = ISO8601DateFormatter().date(from: watermark) {
                sinceDate = parsed
            } else {
                sinceDate = scanStart.addingTimeInterval(-86_400)
            }
        }

        guard FileManager.default.fileExists(atPath: bookmarksPath) else {
            throw AppleTasksError.automationFailed("Safari Bookmarks.plist not found at \(bookmarksPath).")
        }

        guard let data = try? Data(contentsOf: url) else {
            throw AppleTasksError.automationFailed(
                "Could not read Bookmarks.plist. Full Disk Access is required. " +
                "Grant Full Disk Access to this host process in System Settings > Privacy & Security."
            )
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let children = plist["Children"] as? [[String: Any]] else {
            throw AppleTasksError.automationFailed("Invalid Bookmarks.plist format.")
        }

        guard let readingListFolder = children.first(where: { ($0["Title"] as? String) == "com.apple.ReadingList" }),
              let items = readingListFolder["Children"] as? [[String: Any]] else {
            emit([ReadingListItemOut]())
            return
        }

        let isoOut = ISO8601DateFormatter()
        var results: [ReadingListItemOut] = []

        for item in items {
            guard let urlString = item["URLString"] as? String else { continue }

            var title = ""
            if let uriDict = item["URIDictionary"] as? [String: Any], let t = uriDict["title"] as? String {
                title = t
            } else if let t = item["Title"] as? String {
                title = t
            }

            guard let rlMetadata = item["ReadingList"] as? [String: Any],
                  let dateAdded = rlMetadata["DateAdded"] as? Date else { continue }

            let previewText = rlMetadata["PreviewText"] as? String

            if dateAdded > sinceDate {
                results.append(ReadingListItemOut(
                    title: title,
                    url: urlString,
                    dateAdded: isoOut.string(from: dateAdded),
                    previewText: previewText
                ))
            }
        }

        // Sort chronological so they are processed in order
        results.sort(by: { $0.dateAdded < $1.dateAdded })

        let finalResults = Array(results.prefix(maxItems))

        if advanceWatermark {
            var state = ScanState.load()
            state.readingListScanWatermark = isoOut.string(from: scanStart)
            try state.save()
        }

        emit(finalResults)
    }
}
