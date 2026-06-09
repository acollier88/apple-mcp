import ArgumentParser
import Foundation

struct NoteOut: Codable {
    let id: String
    let name: String
    let folder: String?
    let body: String
    let created: String
    let modified: String
}

struct Notes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read Apple Notes (read-only; via Apple Events).",
        subcommands: [NotesScan.self],
        defaultSubcommand: NotesScan.self
    )
}

struct NotesScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        List notes modified since a watermark, with bodies as plain text. \
        Without --since, uses (and advances) the stored watermark; first run looks back 24h.
        """
    )

    @Option(help: "Only scan this Notes folder.")
    var folder: String?

    @Option(help: "Override watermark: yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601. Stateless (does not advance the stored watermark).")
    var since: String?

    @Option(name: .customLong("max-chars"), help: "Truncate each note body to this many characters (default 4000).")
    var maxChars: Int = 4000

    // Bulk property fetches (ids = matched.id()) are one Apple Event each instead of
    // one per note; the per-note fallback only runs when a locked note breaks bulk body().
    private static let script = """
    function run(argv) {
        const since = new Date(Number(argv[0]));
        const folderName = argv[1];
        const app = Application('Notes');
        const source = folderName ? app.folders.byName(folderName) : app;
        const matched = source.notes.whose({ modificationDate: { _greaterThan: since } });
        const ids = matched.id();
        const names = matched.name();
        const mods = matched.modificationDate();
        const cres = matched.creationDate();
        let bodies;
        try {
            bodies = matched.body();
        } catch (e) {
            bodies = ids.map((_, i) => {
                try { return matched[i].body(); } catch (e2) { return ""; }
            });
        }
        const out = [];
        for (let i = 0; i < ids.length; i++) {
            out.push({
                id: ids[i],
                name: names[i],
                body: bodies[i] || "",
                created: cres[i].toISOString(),
                modified: mods[i].toISOString(),
            });
        }
        return JSON.stringify(out);
    }
    """

    func run() async throws {
        let scanStart = Date()
        var state = ScanState.load()

        let sinceDate: Date
        if let since {
            sinceDate = try Dates.parseDateTime(since).date
        } else if let watermark = state.notesScanWatermark,
                  let parsed = ISO8601DateFormatter().date(from: watermark) {
            sinceDate = parsed
        } else {
            sinceDate = scanStart.addingTimeInterval(-86_400)
        }

        let sinceMs = String(Int(sinceDate.timeIntervalSince1970 * 1000))
        let raw = try OSA.runJXA(Self.script, args: [sinceMs, folder ?? ""])

        struct RawNote: Codable {
            let id: String
            let name: String
            let body: String
            let created: String
            let modified: String
        }
        let rawNotes = try JSONDecoder().decode([RawNote].self, from: Data(raw.utf8))
        let notes = rawNotes.map { note in
            NoteOut(
                id: note.id,
                name: note.name,
                folder: folder,
                body: String(HTML.toText(note.body).prefix(maxChars)),
                created: note.created,
                modified: note.modified
            )
        }

        if since == nil {
            state.notesScanWatermark = ISO8601DateFormatter().string(from: scanStart)
            try state.save()
        }
        emit(notes)
    }
}
