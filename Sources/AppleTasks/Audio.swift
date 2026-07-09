import ArgumentParser
import Foundation
import Speech

// IDEAS #21: Voice-note transcription scan. Watermarks an inbox folder (e.g. iCloud
// AgentInbox) for new audio recordings, transcribes them on-device via Speech recognition,
// and emits {file, ts, transcript} JSON for the triage agent to classify.
// Uses an iCloud drop folder so Voice Memos or watch recordings can be shared in from
// any device (avoiding Voice Memos' sandboxed/TCC-protected local storage).

struct AudioOut: Codable {
    let file: String
    let modified: String
    let transcript: String
    var archivedTo: String?
}

struct Audio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe audio notes dropped in the inbox folder.",
        subcommands: [AudioScan.self],
        defaultSubcommand: AudioScan.self
    )
}

struct AudioScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        Transcribe audio files modified since a watermark and emit their text. \
        Without --since, uses (and advances) the stored watermark; first run \
        looks back 24h. --archive moves processed files into a done/ subfolder.
        """
    )

    @Option(help: "Folder to scan (default: iCloud Drive/AgentInbox).")
    var dir: String?

    @Option(help: "Override watermark: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Stateless (does not advance the stored watermark).")
    var since: String?

    @Option(name: .customLong("max-chars"), help: "Truncate recognized text (default 4000).")
    var maxChars: Int = 4000

    @Flag(help: "Move processed files into a done/ subfolder (skips files already there).")
    var archive = false

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aac"]
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
            if let watermark = ScanState.load().audioScanWatermark,
               let parsed = ISO8601DateFormatter().date(from: watermark) {
                sinceDate = parsed
            } else {
                sinceDate = scanStart.addingTimeInterval(-86_400)
            }
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        // Request Speech Recognition TCC access up front if undetermined
        try await requestSpeechAuthorization()

        let isoOut = ISO8601DateFormatter()
        var results: [AudioOut] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified > sinceDate else { continue }

            // Ensure iCloud file is materialized locally
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)

            let transcript = await Self.transcribe(url: url).prefix(maxChars)
            
            var out = AudioOut(file: url.path, modified: isoOut.string(from: modified),
                               transcript: String(transcript), archivedTo: nil)
            if archive {
                out.archivedTo = try Self.archiveFile(url, in: folderURL)
            }
            results.append(out)
        }

        if advanceWatermark {
            var state = ScanState.load()
            state.audioScanWatermark = isoOut.string(from: scanStart)
            try state.save()
        }
        emit(results)
    }

    /// On-device transcription using Speech framework.
    static func transcribe(url: URL) async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return ""
        }
        guard recognizer.isAvailable else {
            return ""
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }

                if error != nil {
                    resumed = true
                    continuation.resume(returning: "")
                    return
                }

                if let result = result {
                    if result.isFinal {
                        resumed = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }

            // Fallback timeout after 30 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if !resumed {
                    resumed = true
                    task.cancel()
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func requestSpeechAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }
    }

    /// Move a processed audio file into <folder>/done/, disambiguating name clashes.
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
