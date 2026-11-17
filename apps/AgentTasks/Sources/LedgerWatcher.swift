import Combine
import Darwin
import Foundation

// Polls the apple-tasks ledger for the menu bar. Reads and vnode-watches
// ~/.config/apple-tasks; never writes it. Pause, resume, and approval
// answers go through the same CLI the ops console already shells out to.

struct PauseSnapshot: Codable, Equatable {
    var paused: Bool = false
    var until: String?
    var reason: String?
    var remainingSeconds: Int?
}

struct PendingApproval: Codable, Identifiable, Equatable {
    let token: String
    let question: String
    let taskId: String?
    let status: String
    let requestedAt: String
    let expiresAt: String?
    let answeredAt: String?
    let answeredVia: String?

    var id: String { token }
}

struct MenuBarSnapshot: Equatable {
    var running: [DispatchLedgerRow] = []
    var failures: [DispatchLedgerRow] = []
    var reviews: [DispatchLedgerRow] = []
    var approvals: [PendingApproval] = []
    var pause = PauseSnapshot()
}

enum ISODate {
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}

enum PauseSchedule {
    /// Next local 7:00am, as an ISO8601 timestamp with a timezone (`dispatch-pause --until`).
    static func untilSevenAM(now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let seven = calendar.date(byAdding: .hour, value: 7, to: start) ?? now
        let target = seven > now ? seven : (calendar.date(byAdding: .day, value: 1, to: seven) ?? seven)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: target)
    }
}

enum PauseFormatting {
    static func statusLine(_ pause: PauseSnapshot, now: Date = Date()) -> String {
        guard pause.paused else { return "Dispatcher running" }
        var line = "Paused"
        if let until = pause.until, let date = ISODate.parse(until) {
            let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
            let time = date.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
            line = "Paused until \(time)"
        }
        if let seconds = pause.remainingSeconds {
            line += " · \(remaining(seconds)) left"
        }
        if let reason = pause.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            line += " · \(reason)"
        }
        return line
    }

    private static func remaining(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }
}

enum MenuBarFetch {
    struct Raw: Sendable {
        var runningJSON: String?
        var failureJSONs: [String] = []
        var reviewJSON: String?
        var approvalJSON: String?
        var pauseJSON: String?
        var errors: [String] = []
        var runningOK = false
        var failuresOK = false
        var reviewOK = false
        var approvalOK = false
        var pauseOK = false
    }

    private static let failureQueries: [(label: String, args: [String])] = [
        ("Failed", ["dispatches", "--status", "failed", "--limit", "8"]),
        ("Timeout", ["dispatches", "--status", "timeout", "--limit", "5"]),
        ("Aborted", ["dispatches", "--status", "aborted", "--limit", "5"]),
    ]

    /// `includeReviews` runs `dispatches --status pending-review`, which also
    /// settles merged branches. The menu asks for that only while it is open
    /// so a background poll does not walk git repos.
    static func load(includeReviews: Bool) -> Raw {
        var raw = Raw()
        if let json = capture(
            ["dispatches", "--status", "running", "--limit", "20"],
            label: "Running", errors: &raw.errors) {
            raw.runningJSON = json
            raw.runningOK = true
        } else if binaryMissing(raw.errors) {
            return raw
        }

        var failures: [String] = []
        var failuresOK = true
        for query in failureQueries {
            if let json = capture(query.args, label: query.label, errors: &raw.errors) {
                failures.append(json)
            } else {
                failuresOK = false
                if binaryMissing(raw.errors) { return raw }
                break
            }
        }
        if failuresOK {
            raw.failureJSONs = failures
            raw.failuresOK = true
        }

        if includeReviews {
            if let json = capture(
                ["dispatches", "--status", "pending-review", "--limit", "20"],
                label: "Reviews", errors: &raw.errors) {
                raw.reviewJSON = json
                raw.reviewOK = true
            } else if binaryMissing(raw.errors) {
                return raw
            }
        }
        if let json = capture(
            ["approve", "list", "--status", "pending", "--limit", "50"],
            label: "Approvals", errors: &raw.errors) {
            raw.approvalJSON = json
            raw.approvalOK = true
        } else if binaryMissing(raw.errors) {
            return raw
        }
        if let json = capture(["dispatch-status"], label: "Pause", errors: &raw.errors) {
            raw.pauseJSON = json
            raw.pauseOK = true
        }
        return raw
    }

    /// A missing binary fails every call the same way; don't stack seven of them.
    private static func binaryMissing(_ errors: [String]) -> Bool {
        guard let last = errors.last?.lowercased() else { return false }
        return last.contains("binary not found") || last.contains("failed to launch")
    }

    private static func capture(_ args: [String], label: String, errors: inout [String]) -> String? {
        do {
            return try CLI.run(args, timeout: 30)
        } catch {
            errors.append("\(label): \(MenuBarText.oneLine(error.localizedDescription))")
            return nil
        }
    }
}

enum MenuBarText {
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "apple-tasks failed" }
        if trimmed.count <= 180 { return trimmed }
        return String(trimmed.prefix(179)) + "…"
    }
}

@MainActor
final class LedgerWatcher: ObservableObject {
    static let shared = LedgerWatcher()

    @Published private(set) var snapshot = MenuBarSnapshot()
    @Published private(set) var errorCaption: String?
    @Published private(set) var actionCaption: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isActing = false
    @Published private(set) var answering: Set<String> = []
    @Published private(set) var notificationsDenied = false

    private var started = false
    private var menuOpen = false
    private var inFlight = false
    private var queued = false
    private var queuedInteractive = false
    private var nextRefreshAt = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var flashToken = UUID()
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: Set<String> = []

    static let failureStatuses: Set<String> = ["failed", "timeout", "aborted"]

    private static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks", isDirectory: true)
    }

    private static var watchPaths: [String] {
        let dir = configDir
        return ["apple-tasks.db", "apple-tasks.db-wal"].map {
            dir.appendingPathComponent($0).path
        }
    }

    private init() {}

    func start() {
        guard !CommandLine.arguments.contains("--whereami") else { return }
        guard !started else { return }
        started = true
        installWatcher()
        Task {
            await LocalNotifications.prepare()
            await refreshNotificationAuthorization()
        }
        Task { await refresh() }
        pollTask = Task { await pollLoop() }
    }

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        guard open else { return }
        Task {
            await refreshNotificationAuthorization()
            await refresh(interactive: true)
        }
    }

    func refresh(interactive: Bool = false) async {
        if inFlight {
            queued = true
            if interactive {
                queuedInteractive = true
                isRefreshing = true
            }
            return
        }
        inFlight = true
        nextRefreshAt = Date().addingTimeInterval(menuOpen ? 30 : 120)
        if interactive { isRefreshing = true }
        installWatcher()
        let includeReviews = menuOpen
        let raw = await Task.detached(priority: .utility) {
            MenuBarFetch.load(includeReviews: includeReviews)
        }.value
        apply(raw)
        let followUp = queued
        let followInteractive = queuedInteractive
        queued = false
        queuedInteractive = false
        inFlight = false
        if followUp {
            await refresh(interactive: followInteractive)
            return
        }
        isRefreshing = false
    }

    func pause(for duration: String) async {
        await mutate(["dispatch-pause", "--for", duration], success: "Paused for \(duration)")
    }

    func pauseUntilSevenAM() async {
        let until = PauseSchedule.untilSevenAM()
        await mutate(["dispatch-pause", "--until", until], success: "Paused until 7am")
    }

    func resume() async {
        await mutate(["dispatch-resume"], success: "Dispatcher resumed")
    }

    /// Mac-side answer (`approve answer`). The audit log records the caller.
    func answer(token: String, approve: Bool) async {
        guard !answering.contains(token) else { return }
        answering.insert(token)
        defer { answering.remove(token) }
        let verdict = approve ? "approve" : "deny"
        do {
            _ = try await runCLI(["approve", "answer", token, verdict])
            flash(approve ? "Approved \(token)" : "Denied \(token)")
        } catch {
            flash(MenuBarText.oneLine(error.localizedDescription))
        }
        await refresh()
    }

    func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self.rebindFilesIfNeeded()
            await self.refresh()
        }
    }

    func refreshNotificationAuthorization() async {
        notificationsDenied = await LocalNotifications.authorizationDenied()
    }

    private func mutate(_ args: [String], success: String) async {
        guard !isActing else { return }
        isActing = true
        defer { isActing = false }
        do {
            _ = try await runCLI(args)
            flash(success)
        } catch {
            flash(MenuBarText.oneLine(error.localizedDescription))
        }
        await refresh()
    }

    private func runCLI(_ args: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            try CLI.run(args, timeout: 30)
        }.value
    }

    private func flash(_ message: String) {
        let token = UUID()
        flashToken = token
        actionCaption = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard self.flashToken == token else { return }
            self.actionCaption = nil
        }
    }

    private func apply(_ raw: MenuBarFetch.Raw) {
        var next = snapshot
        var decodeErrors: [String] = []
        var notifyFailures: [DispatchLedgerRow]?
        var notifyApprovals: [PendingApproval]?

        if raw.runningOK, let json = raw.runningJSON {
            if let rows = decode([DispatchLedgerRow].self, from: json) {
                next.running = rows
            } else {
                decodeErrors.append("Running: could not read apple-tasks output")
            }
        }
        if raw.failuresOK {
            let lists = raw.failureJSONs.compactMap { decode([DispatchLedgerRow].self, from: $0) }
            if lists.count == raw.failureJSONs.count {
                next.failures = Self.mergedFailures(lists)
                notifyFailures = next.failures
            } else {
                decodeErrors.append("Failures: could not read apple-tasks output")
            }
        }
        if raw.reviewOK, let json = raw.reviewJSON {
            if let rows = decode([DispatchLedgerRow].self, from: json) {
                next.reviews = rows
            } else {
                decodeErrors.append("Reviews: could not read apple-tasks output")
            }
        }
        if raw.approvalOK, let json = raw.approvalJSON {
            if let rows = decode([PendingApproval].self, from: json) {
                next.approvals = rows.filter { $0.status == "pending" }
                notifyApprovals = next.approvals
            } else {
                decodeErrors.append("Approvals: could not read apple-tasks output")
            }
        }
        if raw.pauseOK, let json = raw.pauseJSON {
            if let pause = decode(PauseSnapshot.self, from: json) {
                next.pause = pause
            } else {
                decodeErrors.append("Pause: could not read apple-tasks output")
            }
        }

        if next != snapshot { snapshot = next }
        let notes = raw.errors + decodeErrors
        errorCaption = notes.first

        if notifyFailures != nil || notifyApprovals != nil {
            LocalNotifications.deliver(failures: notifyFailures, approvals: notifyApprovals)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func mergedFailures(_ lists: [[DispatchLedgerRow]]) -> [DispatchLedgerRow] {
        var byID: [Int: DispatchLedgerRow] = [:]
        for row in lists.joined() where failureStatuses.contains(row.status) {
            byID[row.id] = row
        }
        return byID.values.sorted { recency($0) > recency($1) }
    }

    private static func recency(_ row: DispatchLedgerRow) -> Date {
        ISODate.parse(row.finishedAt ?? row.startedAt) ?? .distantPast
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if Date() >= nextRefreshAt {
                await refresh()
            }
        }
    }

    /// Directory vnode for create/rename, plus the db and WAL for writes.
    /// `O_EVTONLY` does not write the config directory.
    private func installWatcher() {
        guard directorySource == nil else { return }
        let dir = Self.configDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                LedgerWatcher.shared.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directorySource = source
        rebindFilesIfNeeded()
    }

    private func rebindFilesIfNeeded() {
        let want = Set(Self.watchPaths.filter { FileManager.default.fileExists(atPath: $0) })
        guard want != watchedPaths else { return }
        for source in fileSources { source.cancel() }
        fileSources.removeAll()
        watchedPaths = want
        for path in want {
            guard let source = makeFileSource(path) else { continue }
            fileSources.append(source)
        }
    }

    private func makeFileSource(_ path: String) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                LedgerWatcher.shared.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }
}
