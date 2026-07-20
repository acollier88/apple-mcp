import ArgumentParser
import Foundation
import Speech
import os

// IDEAS #21: Voice-note transcription scan. Watermarks an inbox folder (e.g. iCloud
// AgentInbox) for new audio recordings, transcribes them on-device via Speech recognition,
// and emits {file, ts, transcript} JSON for the triage agent to classify.
// Uses an iCloud drop folder so Voice Memos or watch recordings can be shared in from
// any device (avoiding Voice Memos' sandboxed/TCC-protected local storage).

struct AudioOut: Codable {
    let file: String
    let modified: String
    var transcript: String?
    var archivedTo: String?
    var error: String?
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
        var oldestFailure: Date?
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified > sinceDate else { continue }

            // Ensure iCloud file is materialized locally
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)

            var out = AudioOut(file: url.path, modified: isoOut.string(from: modified),
                               transcript: nil, archivedTo: nil, error: nil)
            switch await Self.transcribe(url: url) {
            case .success(let text):
                out.transcript = String(text.prefix(maxChars))
                // Only archive files that actually transcribed; failures stay
                // in place so the next scan retries them.
                if archive {
                    out.archivedTo = try Self.archiveFile(url, in: folderURL)
                }
            case .failure(let err):
                out.error = err.message
                oldestFailure = min(oldestFailure ?? modified, modified)
            }
            results.append(out)
        }

        if advanceWatermark {
            var state = ScanState.load()
            // A failed file must fall after the watermark so it is retried;
            // park the watermark just before the oldest failure.
            let mark = oldestFailure.map { $0.addingTimeInterval(-1) } ?? scanStart
            state.audioScanWatermark = isoOut.string(from: mark)
            try state.save()
        }
        emit(results)
    }

    struct TranscribeError: Error {
        let message: String
    }

    /// On-device transcription using Speech framework. Failure (unavailable
    /// recognizer, recognition error, timeout) is distinct from an empty
    /// transcript so callers can retry instead of silently losing the memo.
    static func transcribe(url: URL) async -> Result<String, TranscribeError> {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return .failure(TranscribeError(message: "speech recognizer unavailable for locale"))
        }
        guard recognizer.isAvailable else {
            return .failure(TranscribeError(message: "speech recognizer not available (on-device model missing?)"))
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // The recognition callback and the timeout fire on different queues;
        // the lock guarantees the continuation resumes exactly once.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        func resumeOnce(_ body: () -> Void) {
            let first = resumed.withLock { done in
                if done { return false }
                done = true
                return true
            }
            if first { body() }
        }

        return await withCheckedContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce { continuation.resume(returning: .failure(
                        TranscribeError(message: error.localizedDescription))) }
                    return
                }
                if let result, result.isFinal {
                    resumeOnce { continuation.resume(returning: .success(
                        result.bestTranscription.formattedString)) }
                }
            }

            // Fallback timeout after 30 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                resumeOnce {
                    task.cancel()
                    continuation.resume(returning: .failure(TranscribeError(message: "transcription timed out (30s)")))
                }
            }
        }
    }

    private func requestSpeechAuthorization() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            // In non-app hosts the authorization callback may never fire
            // (no UI to attach the TCC prompt to) -- don't hang the scan.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { result in
                    let first = resumed.withLock { done in
                        if done { return false }
                        done = true
                        return true
                    }
                    if first { continuation.resume(returning: result) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    let first = resumed.withLock { done in
                        if done { return false }
                        done = true
                        return true
                    }
                    if first { continuation.resume(returning: SFSpeechRecognizer.authorizationStatus()) }
                }
            }
        }
        guard status == .authorized else {
            throw AppleTasksError.automationFailed(
                "Speech recognition not authorized (status: \(Self.describe(status))). " +
                "Run once from Terminal to get the TCC prompt, or grant it in " +
                "System Settings > Privacy & Security > Speech Recognition.")
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
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
