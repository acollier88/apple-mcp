import ArgumentParser
import CryptoKit
import Foundation

// IDEAS #38: topic watches / standing monitors. Config lists feeds/pages to
// watch; `watch scan` fetches each due watch, diffs against per-watch state
// (state.json, same store as every other scan), and emits only NEW items.
// Consumers are the same as the sibling scans: triage decides digest-worthy
// vs. noise, hits become [read] tasks with the url field. The `web fetch`
// primitive lives here too (same IDEAS item): it gives the local triage
// lane web context without granting it a browser.

// MARK: - config (~/.config/apple-tasks/watches.json)

struct WatchDef: Codable {
    enum Kind: String, Codable { case rss, url }
    let name: String
    let kind: Kind
    let url: String
    /// Minutes between fetches (default 60). A watch whose cadence has not
    /// elapsed since its last fetch is skipped; --force fetches regardless.
    let cadenceMinutes: Int?
}

struct WatchesConfig: Codable {
    let watches: [WatchDef]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/watches.json")
    }

    static func load() throws -> WatchesConfig {
        guard let data = try? Data(contentsOf: url) else {
            throw AppleTasksError.saveFailed(
                "no watches config at \(url.path); create it to enable watches, e.g. " +
                #"{"watches": [{"name": "swift-blog", "kind": "rss", "url": "https://swift.org/atom.xml"}]}"#)
        }
        let config = try JSONDecoder().decode(WatchesConfig.self, from: data)
        var seen = Set<String>()
        for watch in config.watches {
            guard seen.insert(watch.name.lowercased()).inserted else {
                throw AppleTasksError.saveFailed("duplicate watch name '\(watch.name)' in \(url.path)")
            }
        }
        return config
    }
}

/// Per-watch scan state, keyed by watch name in ScanState.watchState.
struct WatchRecord: Codable {
    /// ISO8601 of the last completed fetch (cadence anchor).
    var lastFetch: String?
    /// RSS: ids (guid, else link) already emitted; capped at 500, newest last.
    var seenIds: [String]?
    /// url kind: SHA-256 of the last page body.
    var contentHash: String?
}

struct WatchItemOut: Codable {
    let watch: String
    let kind: String
    /// Item timestamp (feed pubDate when parseable, else scan time), ISO8601.
    let ts: String
    let title: String?
    let url: String
    /// Extra context: "content changed" for url watches, feed summary if any.
    let note: String?
}

// MARK: - commands

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Standing monitors over RSS feeds and web pages (config: ~/.config/apple-tasks/watches.json).",
        subcommands: [WatchScan.self, WatchList.self],
        defaultSubcommand: WatchScan.self
    )
}

struct WatchList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show configured watches and their scan state."
    )

    struct Out: Codable {
        let name: String
        let kind: String
        let url: String
        let cadenceMinutes: Int
        let lastFetch: String?
        let due: Bool
    }

    func run() async throws {
        let config = try WatchesConfig.load()
        let state = ScanState.load().watchState ?? [:]
        emit(config.watches.map { watch in
            let record = state[watch.name]
            return Out(name: watch.name, kind: watch.kind.rawValue, url: watch.url,
                       cadenceMinutes: watch.cadenceMinutes ?? 60,
                       lastFetch: record?.lastFetch,
                       due: WatchScan.isDue(watch, record: record, asOf: Date()))
        })
    }
}

struct WatchScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        Fetch each due watch and emit items new since the last scan. First \
        run of an RSS watch emits the last 24h and seeds the seen-set; first \
        run of a url watch just records the baseline. Skipped and failed \
        watches are reported per-watch, never fatal for the scan.
        """
    )

    @Option(name: .customLong("watch"), help: "Only scan this watch (by name).")
    var onlyWatch: String?

    @Flag(help: "Fetch every watch now, ignoring cadence.")
    var force = false

    @Option(name: .customLong("max-items"), help: "Per-watch cap on emitted items (default 20).")
    var maxItems: Int = 20

    struct Out: Codable {
        let scannedAt: String
        let items: [WatchItemOut]
        let watches: [WatchReport]
        struct WatchReport: Codable {
            let name: String
            let status: String   // "ok" | "skipped: not due" | "baseline recorded" | "error: ..."
            let newItems: Int
        }
    }

    static func isDue(_ watch: WatchDef, record: WatchRecord?, asOf: Date) -> Bool {
        guard let last = record?.lastFetch,
              let lastDate = ISO8601DateFormatter().date(from: last) else { return true }
        let cadence = TimeInterval((watch.cadenceMinutes ?? 60) * 60)
        return asOf.timeIntervalSince(lastDate) >= cadence
    }

    func run() async throws {
        let config = try WatchesConfig.load()
        var watches = config.watches
        if let onlyWatch {
            watches = watches.filter { $0.name.caseInsensitiveCompare(onlyWatch) == .orderedSame }
            guard !watches.isEmpty else {
                throw AppleTasksError.saveFailed("no watch named '\(onlyWatch)' in \(WatchesConfig.url.path)")
            }
        }

        let scanStart = Date()
        let iso = ISO8601DateFormatter()
        var state = ScanState.load()
        var watchState = state.watchState ?? [:]
        var items: [WatchItemOut] = []
        var reports: [Out.WatchReport] = []

        for watch in watches {
            var record = watchState[watch.name] ?? WatchRecord()
            guard force || Self.isDue(watch, record: record, asOf: scanStart) else {
                reports.append(.init(name: watch.name, status: "skipped: not due", newItems: 0))
                continue
            }

            do {
                let body = try await WebGet.fetch(watch.url)
                let (newItems, status) = diff(watch: watch, body: body, record: &record,
                                              scanStart: scanStart, iso: iso)
                record.lastFetch = iso.string(from: scanStart)
                watchState[watch.name] = record
                items.append(contentsOf: newItems)
                reports.append(.init(name: watch.name, status: status, newItems: newItems.count))
            } catch {
                // A dead feed must not starve the others; cadence still
                // advances so a permanently-broken watch retries on schedule
                // instead of on every pass.
                record.lastFetch = iso.string(from: scanStart)
                watchState[watch.name] = record
                reports.append(.init(name: watch.name, status: "error: \(error.localizedDescription)", newItems: 0))
            }
        }

        state.watchState = watchState
        try state.save()
        AuditDB.shared.record(command: "watch scan",
                              detail: "\(items.count) new item(s) across \(reports.count) watch(es)")
        emit(Out(scannedAt: iso.string(from: scanStart), items: items, watches: reports))
    }

    /// Diff fetched content against the watch's record, mutating the record.
    private func diff(watch: WatchDef, body: Data, record: inout WatchRecord,
                      scanStart: Date, iso: ISO8601DateFormatter) -> ([WatchItemOut], String) {
        switch watch.kind {
        case .url:
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            defer { record.contentHash = hash }
            guard let previous = record.contentHash else { return ([], "baseline recorded") }
            guard previous != hash else { return ([], "ok") }
            return ([WatchItemOut(watch: watch.name, kind: "url", ts: iso.string(from: scanStart),
                                  title: nil, url: watch.url, note: "content changed")], "ok")

        case .rss:
            let feedItems = FeedParser.parse(body)
            var seen = record.seenIds ?? []
            let seenSet = Set(seen)
            let firstRun = record.seenIds == nil
            let cutoff = scanStart.addingTimeInterval(-86_400)

            var fresh: [WatchItemOut] = []
            for item in feedItems where !seenSet.contains(item.dedupeId) {
                seen.append(item.dedupeId)
                // First run: seed the seen-set with the whole feed but only
                // surface the last 24h — mirrors the sibling scans' lookback.
                if firstRun, (item.date ?? .distantPast) <= cutoff { continue }
                fresh.append(WatchItemOut(watch: watch.name, kind: "rss",
                                          ts: iso.string(from: item.date ?? scanStart),
                                          title: item.title, url: item.link ?? watch.url,
                                          note: item.summary))
            }
            record.seenIds = Array(seen.suffix(500))
            fresh.sort { $0.ts < $1.ts }
            if fresh.count > maxItems {
                // Cap keeps the NEWEST; the overflow was seen-marked above,
                // so it will not re-surface — a firehose feed stays bounded.
                fresh = Array(fresh.suffix(maxItems))
            }
            return (fresh, firstRun && fresh.isEmpty ? "baseline recorded" : "ok")
        }
    }
}

// MARK: - RSS / Atom parsing (XMLParser, no dependencies)

struct FeedItem {
    var title: String?
    var link: String?
    var guid: String?
    var summary: String?
    var date: Date?
    var dedupeId: String { guid ?? link ?? (title ?? "") }
}

enum FeedParser {
    static func parse(_ data: Data) -> [FeedItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        private var current: FeedItem?
        private var text = ""
        private var element = ""

        private static let rfc822: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f
        }()

        private static func parseDate(_ s: String) -> Date? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return rfc822.date(from: trimmed)
                ?? ISO8601DateFormatter().date(from: trimmed)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            element = name
            text = ""
            switch name {
            case "item", "entry":
                current = FeedItem()
            case "link":
                // Atom links carry the URL as an attribute; prefer rel=alternate.
                if current != nil, let href = attributes["href"],
                   attributes["rel"] == nil || attributes["rel"] == "alternate" {
                    current?.link = href
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item", "entry":
                if let item = current { items.append(item) }
                current = nil
            case "title":
                if current?.title == nil { current?.title = value }
            case "link":
                // RSS carries the URL as element text (Atom handled at start).
                if current?.link == nil, !value.isEmpty { current?.link = value }
            case "guid", "id":
                if current?.guid == nil, !value.isEmpty { current?.guid = value }
            case "description", "summary":
                if current?.summary == nil, !value.isEmpty {
                    current?.summary = String(HTML.toText(value).prefix(300))
                }
            case "pubDate", "published", "updated":
                if current?.date == nil { current?.date = Self.parseDate(value) }
            default:
                break
            }
        }
    }
}

// MARK: - web fetch (qwen #6: web context for the local triage lane)

struct Web: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Minimal web primitives for agents without their own web access.",
        subcommands: [WebGet.self]
    )
}

struct WebGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch a URL and emit {url, status, title, text} with HTML reduced to readable text."
    )

    @Argument(help: "http(s) URL to fetch.")
    var url: String

    @Option(name: .customLong("max-chars"), help: "Truncate extracted text to this many characters (default 4000).")
    var maxChars: Int = 4000

    struct Out: Codable {
        let url: String
        let status: Int
        let contentType: String?
        let title: String?
        let text: String
        let truncated: Bool
    }

    /// Shared GET with a UA (some feed hosts reject UA-less requests).
    /// Throws on non-2xx so callers treat redirect loops/404s as failures.
    static func fetch(_ urlString: String) async throws -> Data {
        let (data, response) = try await request(urlString)
        guard (200..<300).contains(response.statusCode) else {
            throw AppleTasksError.automationFailed("HTTP \(response.statusCode) from \(urlString)")
        }
        return data
    }

    static func request(_ urlString: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            throw AppleTasksError.saveFailed("not an http(s) URL: \(urlString)")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("apple-tasks/0.1 (+watch-scan)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppleTasksError.automationFailed("non-HTTP response from \(urlString)")
        }
        return (data, http)
    }

    func run() async throws {
        let (data, response) = try await Self.request(url)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let raw = String(data: data, encoding: .utf8) ?? ""

        var title: String?
        var text = raw
        if contentType?.contains("html") ?? raw.lowercased().contains("<html") {
            if let range = raw.range(of: "<title[^>]*>([^<]*)</title>",
                                     options: [.regularExpression, .caseInsensitive]) {
                title = HTML.toText(String(raw[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Drop script/style/head bodies before tag-stripping, else their
            // contents (JS, CSS) would survive as "text".
            for block in ["script", "style", "noscript", "head", "svg"] {
                text = text.replacingOccurrences(
                    of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>", with: " ",
                    options: [.regularExpression, .caseInsensitive])
            }
            text = HTML.toText(text)
        }
        let truncated = text.count > maxChars
        if truncated { text = String(text.prefix(maxChars)) }

        AuditDB.shared.record(command: "web fetch", detail: url)
        emit(Out(url: url, status: response.statusCode, contentType: contentType,
                 title: title, text: text, truncated: truncated))
    }
}
