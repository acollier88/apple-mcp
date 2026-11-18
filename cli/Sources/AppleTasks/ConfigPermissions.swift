import Darwin
import Foundation

/// Owner-only modes for `~/.config/apple-tasks` and what it holds (#30).
///
/// Everything takes explicit URLs so tests run against a temp directory;
/// nothing here resolves the real config dir. All chmods are best effort:
/// a failure is skipped, never thrown, so no command fails over a mode.
/// Only ever *removes* permission bits (`current & target`), never adds,
/// and never follows symlinks.
enum ConfigPermissions {
    static let privateDirectoryMode = 0o700
    static let privateFileMode = 0o600

    struct ModeChange: Codable, Equatable {
        let path: String
        /// Octal, e.g. "644".
        let from: String
        let to: String
    }

    // MARK: - Primitives

    /// lstat-based mode, nil when missing or of a different kind.
    static func mode(of url: URL, directory: Bool) -> Int? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG) else { return nil }
        return Int(st.st_mode) & 0o777
    }

    /// Drop any bits outside `target`. Returns the change, or nil when the
    /// path is missing, a symlink / other kind, already tight, or chmod failed.
    @discardableResult
    static func tighten(_ url: URL, to target: Int, directory: Bool) -> ModeChange? {
        guard let current = mode(of: url, directory: directory) else { return nil }
        let wanted = current & target
        guard wanted != current else { return nil }
        guard chmod(url.path, mode_t(wanted)) == 0 else { return nil }
        return ModeChange(path: url.path, from: String(current, radix: 8), to: String(wanted, radix: 8))
    }

    /// Create `dir` 0700 if missing (parents get default modes), else tighten.
    @discardableResult
    static func ensurePrivateDirectory(_ dir: URL) -> ModeChange? {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: privateDirectoryMode])
            // createDirectory's attributes are masked by umask; be explicit.
            _ = chmod(dir.path, mode_t(privateDirectoryMode))
            return nil
        }
        return tighten(dir, to: privateDirectoryMode, directory: true)
    }

    /// SQLite sidecars that share the DB's contents.
    static func databaseSidecars(_ db: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: db.path + $0) }
    }

    /// Before `sqlite3_open`: private parent dir, and the DB file created
    /// 0600 if missing (SQLite gives `-wal`/`-shm` the DB file's mode).
    static func prepareDatabase(_ db: URL) {
        ensurePrivateDirectory(db.deletingLastPathComponent())
        let fd = open(db.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(privateFileMode))
        if fd >= 0 {
            close(fd)
        } else {
            tighten(db, to: privateFileMode, directory: false)
        }
    }

    /// After open (WAL mode): tighten DB + sidecars that pre-date this code.
    @discardableResult
    static func tightenDatabase(_ db: URL) -> [ModeChange] {
        ([db] + databaseSidecars(db)).compactMap { tighten($0, to: privateFileMode, directory: false) }
    }

    // MARK: - doctor --fix-modes

    /// Directory, ledger DB + sidecars, `logs/` and `runs/` (dirs 0700,
    /// regular files directly inside 0600), `agents.json` and
    /// `agents.json.bak-*` (lane `env` can hold API keys).
    static func fixModes(configDir: URL, supportDir: URL? = nil) -> [ModeChange] {
        var changes: [ModeChange] = []
        let fm = FileManager.default
        if let change = tighten(configDir, to: privateDirectoryMode, directory: true) { changes.append(change) }

        changes += tightenDatabase(configDir.appendingPathComponent("apple-tasks.db"))

        var directories: [URL] = ["logs", "runs"].map { configDir.appendingPathComponent($0, isDirectory: true) }
        if let supportDir {
            if let change = tighten(supportDir, to: privateDirectoryMode, directory: true) { changes.append(change) }
            directories.append(supportDir.appendingPathComponent("runs", isDirectory: true))
        }
        for dir in directories {
            changes += tightenTree(dir)
        }

        let names = (try? fm.contentsOfDirectory(atPath: configDir.path)) ?? []
        for name in names.sorted() where name == "agents.json" || name.hasPrefix("agents.json.bak") || name == "watches.json" {
            if let change = tighten(configDir.appendingPathComponent(name), to: privateFileMode, directory: false) {
                changes.append(change)
            }
        }
        return changes
    }

    /// `logs/` and `runs/` including nested directories. Symlinks are skipped.
    private static func tightenTree(_ dir: URL) -> [ModeChange] {
        var changes: [ModeChange] = []
        if let change = tighten(dir, to: privateDirectoryMode, directory: true) { changes.append(change) }
        guard mode(of: dir, directory: true) != nil else { return changes }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() {
            let child = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(child.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                changes += tightenTree(child)
            case S_IFREG:
                if let change = tighten(child, to: privateFileMode, directory: false) {
                    changes.append(change)
                }
            default:
                break
            }
        }
        return changes
    }
}
