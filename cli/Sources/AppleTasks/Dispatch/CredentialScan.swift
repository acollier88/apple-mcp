import Foundation

/// Post-run check of an agent's run log for references to well-known
/// credential paths (#27, after #6: an agent tried to read credential files
/// mid-run). It only flags; it never fails a run. A mention is not proof
/// of a read (an agent may print a path it decided not to open), and an
/// agent that reads a file without echoing the path leaves nothing here.
enum CredentialScan {
    /// (label shown in reports — no spaces or commas, lowercased substring to find).
    static let substrings: [(label: String, needle: String)] = [
        (".ssh/", ".ssh/"),
        ("gh/hosts.yml", "gh/hosts.yml"),
        (".aws/credentials", ".aws/credentials"),
        (".netrc", ".netrc"),
        ("Keychains/", "keychains/"),
        ("security-find-password", "security find-generic-password"),
        ("security-find-password", "security find-internet-password"),
        ("security-dump-keychain", "security dump-keychain"),
        ("launchd.env", "launchd.env"),
        ("gmail/token.json", "gmail/token.json"),
        ("gmail/credentials.json", "gmail/credentials.json"),
        ("findmy/account.json", "findmy/account.json"),
    ]

    /// Trailer / report fragment, or nil when nothing matched.
    static func summary(_ labels: [String]) -> String? {
        labels.isEmpty ? nil : "cred-paths-in-log=" + labels.joined(separator: ",")
    }

    /// Successes are not paged, even when the log mentioned a credential
    /// path. Those mentions false-positive on lanes that touch their own
    /// dotenv file (#50).
    static func shouldPush(status: String) -> Bool {
        status != "succeeded"
    }

    /// `.env` / `.env.local` as a path component, not `process.env` or
    /// `launchd.env` (that one has its own label) or `.envrc`.
    static let dotenv = try! NSRegularExpression(
        pattern: #"(?:^|[\s/'"`=:(])\.env(?:\.[A-Za-z0-9_-]+)?(?=$|[\s'"`):;,])"#,
        options: [.anchorsMatchLines])

    /// Bytes read from each end of a large log.
    static let defaultWindow = 1 << 20

    /// Pure: distinct labels in first-seen order (by pattern table order).
    static func matches(in text: String) -> [String] {
        let lower = text.lowercased()
        var out: [String] = []
        for (label, needle) in substrings where !out.contains(label) && lower.contains(needle) {
            out.append(label)
        }
        let range = NSRange(text.startIndex..., in: text)
        if dotenv.firstMatch(in: text, range: range) != nil { out.append(".env") }
        return out
    }

    /// Drop the dispatcher's own header (leading `# ` lines up to the first
    /// blank line) so the task title or argv written there is not scanned.
    static func stripHeader(_ text: String) -> String {
        guard text.hasPrefix("# ") else { return text }
        if let r = text.range(of: "\n\n") { return String(text[r.upperBound...]) }
        return ""
    }

    /// Scan a run log, reading at most `window` bytes from the start and
    /// `window` from the end. Missing/unreadable log → [].
    static func scanLog(at path: String, window: Int = defaultWindow) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var text: String
        if size <= UInt64(window * 2) {
            text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        } else {
            let head = (try? handle.read(upToCount: window)) ?? Data()
            try? handle.seek(toOffset: size - UInt64(window))
            let tail = (try? handle.read(upToCount: window)) ?? Data()
            text = String(decoding: head, as: UTF8.self) + "\n"
                + String(decoding: tail, as: UTF8.self)
        }
        text = stripHeader(text)
        return matches(in: text)
    }
}
