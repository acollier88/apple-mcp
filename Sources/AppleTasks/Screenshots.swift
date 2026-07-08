import ArgumentParser
import Foundation
import Vision

// IDEAS #20: screenshot OCR as a capture channel. The phone habit
// "screenshot it to deal with later" becomes a real inbox: watermark over a
// folder (default ~/Desktop), Vision text recognition per new image, emit
// {file, ts, text} JSON. On-device, free, no TCC beyond folder access. The
// triage agent reads the text and decides task/event/noise, keeping the
// screenshot filename as provenance. Photos library is deliberately out of
// scope (separate TCC + heavier API) — Desktop screenshots only.

struct ScreenshotOut: Codable {
    let file: String
    let modified: String
    let text: String
}

struct Screenshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "OCR screenshots as a capture channel (read-only, on-device Vision).",
        subcommands: [ScreenshotsScan.self],
        defaultSubcommand: ScreenshotsScan.self
    )
}

struct ScreenshotsScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        OCR images modified since a watermark and emit their text. Without \
        --since, uses (and advances) the stored watermark; first run looks back 24h.
        """
    )

    @Option(help: "Folder to scan (default: ~/Desktop).")
    var dir: String?

    @Option(help: "Override watermark: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Stateless (does not advance the stored watermark).")
    var since: String?

    @Option(name: .customLong("max-chars"), help: "Truncate each image's recognized text (default 4000).")
    var maxChars: Int = 4000

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    func run() async throws {
        let scanStart = Date()
        let folder = dir.map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)

        let sinceDate: Date
        var advanceWatermark = false
        if let since {
            sinceDate = try Dates.parseDateTime(since).date
        } else {
            advanceWatermark = true
            if let watermark = ScanState.load().screenshotsScanWatermark,
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
        var results: [ScreenshotOut] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified > sinceDate else { continue }
            let text = Self.recognizeText(in: url).prefix(maxChars)
            results.append(ScreenshotOut(file: url.path, modified: isoOut.string(from: modified),
                                         text: String(text)))
        }

        if advanceWatermark {
            var state = ScanState.load()
            state.screenshotsScanWatermark = isoOut.string(from: scanStart)
            try state.save()
        }
        emit(results)
    }

    /// On-device OCR; returns "" for images with no recognizable text.
    static func recognizeText(in url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
