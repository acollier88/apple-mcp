import AppKit
import ArgumentParser
import Foundation

// IDEAS #45: clipboard capture. NSPasteboard only exposes the CURRENT
// contents — there is no history — so each scan emits at most one clipping:
// the clipboard's text, if the pasteboard changed since the last scan
// (changeCount watermark in ScanState). Call it from a loop or dispatch
// pass to make "copy it to deal with later" a capture channel. Deliberately
// opt-in per run — no daemon, no launchd by default (noisy channel).
//
// Privacy posture: password-manager clippings marked
// org.nspasteboard.ConcealedType (and transient ones) are never surfaced;
// the very first run only records a baseline so a stale secret already on
// the clipboard can't leak into the first scan; clipboard bodies are never
// audit-logged (scans aren't audited at all).

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Clipboard capture: surface new text clippings for triage.",
        subcommands: [ClipboardScan.self],
        defaultSubcommand: ClipboardScan.self
    )
}

struct ClippingOut: Codable {
    let ts: String
    let content: String
    let truncated: Bool
}

struct ClipboardScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Emit the clipboard's text if it changed since the last scan."
    )

    @Option(name: .customLong("max-chars"), help: "Truncate the clipping to this many characters (default 4000).")
    var maxChars: Int = 4000

    func run() async throws {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        var state = ScanState.load()

        // First run: record a baseline only, so whatever is already on the
        // clipboard (possibly copied long ago, possibly secret) never leaks
        // into scan output.
        guard let last = state.clipboardChangeCount else {
            state.clipboardChangeCount = count
            try state.save()
            emit([ClippingOut]())
            return
        }
        guard count != last else {
            emit([ClippingOut]())
            return
        }
        // Advance the watermark even when the clipping is skipped below, so
        // a concealed/non-text clipping doesn't resurface as "new" forever.
        state.clipboardChangeCount = count
        try state.save()

        let skipMarkers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
            .map { NSPasteboard.PasteboardType(rawValue: $0) }
        let types = pasteboard.types ?? []
        guard !skipMarkers.contains(where: types.contains),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            emit([ClippingOut]())
            return
        }

        let truncated = text.count > maxChars
        let content = truncated ? String(text.prefix(maxChars)) : text
        emit([ClippingOut(ts: Dates.formatTimestamp(Date()) ?? "",
                          content: content, truncated: truncated)])
    }
}
