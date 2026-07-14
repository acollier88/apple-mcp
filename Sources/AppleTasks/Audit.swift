import Foundation
import SQLite3

// Machine-side memory: append-only audit of mutations + mutable dispatch
// ledger. Reminders remains the source of truth for task state.
final class AuditDB {
    static let shared = AuditDB()

    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/apple-tasks.db")
    }

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(Self.url.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            caller TEXT NOT NULL,
            command TEXT NOT NULL,
            task_id TEXT,
            list TEXT,
            detail TEXT,
            result TEXT NOT NULL,
            error TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS dispatches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            agent TEXT NOT NULL,
            command TEXT NOT NULL,
            cwd TEXT,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            status TEXT NOT NULL,
            exit_code INTEGER
        )
        """)
        // Older DBs predate these columns; ALTER errors are ignored when they exist.
        exec("ALTER TABLE dispatches ADD COLUMN run_log_path TEXT")
        exec("ALTER TABLE dispatches ADD COLUMN worktree TEXT")
        exec("ALTER TABLE dispatches ADD COLUMN summary TEXT")
        exec("""
        CREATE TABLE IF NOT EXISTS approvals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE,
            task_id TEXT,
            question TEXT NOT NULL,
            requested_at TEXT NOT NULL,
            expires_at TEXT,
            answered_at TEXT,
            status TEXT NOT NULL,
            answered_via TEXT
        )
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static var caller: String {
        if let explicit = ProcessInfo.processInfo.environment["APPLE_TASKS_CALLER"] {
            return explicit
        }
        let ppid = getppid()
        var name = [CChar](repeating: 0, count: 1024)
        if proc_name(ppid, &name, UInt32(name.count)) > 0 {
            return "\(String(cString: name)) (pid \(ppid))"
        }
        return "pid \(ppid)"
    }

    // MARK: Audit

    func record(command: String, taskId: String? = nil, list: String? = nil,
                detail: String? = nil, result: String = "ok", error: String? = nil) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO audit (ts, caller, command, task_id, list, detail, result, error) VALUES (?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let values: [String?] = [Self.now(), Self.caller, command, taskId, list, detail, result, error]
        for (index, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, Int32(index + 1))
            }
        }
        sqlite3_step(stmt)
    }

    struct AuditRow: Codable {
        let ts: String
        let caller: String
        let command: String
        let taskId: String?
        let list: String?
        let detail: String?
        let result: String
        let error: String?
    }

    func auditRows(since: String?, taskId: String?, caller: String?, limit: Int) -> [AuditRow] {
        guard db != nil else { return [] }
        var sql = "SELECT ts, caller, command, task_id, list, detail, result, error FROM audit WHERE 1=1"
        var binds: [String] = []
        if let since { sql += " AND ts >= ?"; binds.append(since) }
        if let taskId { sql += " AND task_id = ?"; binds.append(taskId) }
        if let caller { sql += " AND caller LIKE ?"; binds.append("%\(caller)%") }
        sql += " ORDER BY id DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, bind) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), bind, -1, SQLITE_TRANSIENT)
        }
        var rows: [AuditRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            rows.append(AuditRow(
                ts: col(0) ?? "", caller: col(1) ?? "", command: col(2) ?? "",
                taskId: col(3), list: col(4), detail: col(5),
                result: col(6) ?? "", error: col(7)))
        }
        return rows
    }

    // MARK: Dispatch ledger

    struct DispatchRow: Codable {
        let id: Int
        let taskId: String
        let agent: String
        let command: String
        let cwd: String?
        let startedAt: String
        let finishedAt: String?
        let status: String
        let exitCode: Int?
        let runLogPath: String?
        let worktree: String?
        let summary: String?
    }

    /// Finished runs that still have a worktree on record (GC candidates).
    func worktreeRows() -> [DispatchRow] {
        selectDispatches(
            where: "worktree IS NOT NULL AND status IN ('succeeded','failed','timeout')",
            binds: [], limit: 500)
    }

    /// Clear the worktree column once GC has reclaimed (or lost track of) it.
    func clearWorktree(id: Int64) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE dispatches SET worktree = NULL WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    /// Number of dispatches currently 'running' for an agent (per-agent cap).
    func activeDispatchCount(agent: String) -> Int {
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM dispatches WHERE agent = ? AND status = 'running'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, agent, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// True if this task already has a running or succeeded dispatch.
    func hasActiveDispatch(taskId: String) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM dispatches WHERE task_id = ? AND status IN ('running','succeeded')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, taskId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    /// Atomically claim the dispatch for a task: inserts a 'running' row only
    /// if no running/succeeded row exists, in one statement, so two
    /// dispatchers (cron + manual) cannot both claim. Returns the ledger id,
    /// nil if another dispatcher already holds the claim, or -1 when the
    /// ledger DB is unavailable (dispatch proceeds unledgered, as before).
    func claimDispatch(taskId: String, agent: String, command: String, cwd: String?) -> Int64? {
        guard db != nil else { return -1 }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO dispatches (task_id, agent, command, cwd, started_at, status)
        SELECT ?1, ?2, ?3, ?4, ?5, 'running'
        WHERE NOT EXISTS (SELECT 1 FROM dispatches WHERE task_id = ?1 AND status IN ('running','succeeded'))
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [taskId, agent, command, cwd ?? "", Self.now()].enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        guard sqlite3_changes(db) > 0 else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func setDispatchPaths(id: Int64, runLogPath: String?, worktree: String?) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE dispatches SET run_log_path = ?, worktree = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [runLogPath, worktree].enumerated() {
            if let value {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, Int32(index + 1))
            }
        }
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    /// Rows stuck in 'running' since before the cutoff: marks them 'timeout'
    /// and returns them so the dispatcher can fix the tasks' tags.
    func reapStale(before cutoff: String) -> [DispatchRow] {
        guard db != nil else { return [] }
        let stale = selectDispatches(
            where: "status = 'running' AND started_at < ?", binds: [cutoff], limit: 1000)
        guard !stale.isEmpty else { return [] }
        var stmt: OpaquePointer?
        let sql = "UPDATE dispatches SET finished_at = ?, status = 'timeout' WHERE status = 'running' AND started_at < ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.now(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, cutoff, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        return stale
    }

    /// Failed/timed-out attempt count and latest finish time, for retry backoff.
    func failedAttempts(taskId: String) -> (count: Int, lastFinishedAt: String?) {
        guard db != nil else { return (0, nil) }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*), MAX(finished_at) FROM dispatches WHERE task_id = ? AND status IN ('failed','timeout')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, taskId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil) }
        let last = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        return (Int(sqlite3_column_int(stmt, 0)), last)
    }

    func finishDispatch(id: Int64, status: String, exitCode: Int32, summary: String? = nil) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE dispatches SET finished_at = ?, status = ?, exit_code = ?, summary = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.now(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, status, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, exitCode)
        if let summary {
            sqlite3_bind_text(stmt, 4, summary, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, id)
        sqlite3_step(stmt)
    }

    func dispatchRows(status: String?, limit: Int) -> [DispatchRow] {
        if let status {
            return selectDispatches(where: "status = ?", binds: [status], limit: limit)
        }
        return selectDispatches(where: "1=1", binds: [], limit: limit)
    }

    private func selectDispatches(where clause: String, binds: [String], limit: Int) -> [DispatchRow] {
        guard db != nil else { return [] }
        let sql = """
        SELECT id, task_id, agent, command, cwd, started_at, finished_at, status, exit_code, \
        run_log_path, worktree, summary FROM dispatches WHERE \(clause) ORDER BY id DESC LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, bind) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), bind, -1, SQLITE_TRANSIENT)
        }
        var rows: [DispatchRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            rows.append(DispatchRow(
                id: Int(sqlite3_column_int64(stmt, 0)),
                taskId: col(1) ?? "", agent: col(2) ?? "", command: col(3) ?? "",
                cwd: col(4), startedAt: col(5) ?? "", finishedAt: col(6),
                status: col(7) ?? "",
                exitCode: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8)),
                runLogPath: col(9), worktree: col(10), summary: col(11)))
        }
        return rows
    }

    // MARK: Approvals (IDEAS #39)

    struct ApprovalRow: Codable {
        let id: Int
        let token: String
        let taskId: String?
        let question: String
        let requestedAt: String
        let expiresAt: String?
        let answeredAt: String?
        let status: String        // pending | approved | denied | expired
        let answeredVia: String?  // "ntfy" | "cli"
    }

    func createApproval(token: String, taskId: String?, question: String, expiresAt: String?) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO approvals (token, task_id, question, requested_at, expires_at, status) VALUES (?,?,?,?,?,'pending')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [token, taskId, question, Self.now(), expiresAt].enumerated() {
            if let value {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, Int32(index + 1))
            }
        }
        sqlite3_step(stmt)
    }

    /// Flip a pending approval to a final status. Single-statement
    /// compare-and-set: false when the row is missing or already answered,
    /// so a late ntfy tap can't overwrite a CLI answer (first answer wins).
    func answerApproval(token: String, status: String, via: String) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        let sql = "UPDATE approvals SET status = ?, answered_at = ?, answered_via = ? WHERE token = ? AND status = 'pending'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [status, Self.now(), via, token].enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
    }

    func approvalRows(token: String? = nil, status: String? = nil, limit: Int = 50) -> [ApprovalRow] {
        guard db != nil else { return [] }
        var sql = """
        SELECT id, token, task_id, question, requested_at, expires_at, answered_at, status, answered_via \
        FROM approvals WHERE 1=1
        """
        var binds: [String] = []
        if let token { sql += " AND token = ?"; binds.append(token) }
        if let status { sql += " AND status = ?"; binds.append(status) }
        sql += " ORDER BY id DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, bind) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), bind, -1, SQLITE_TRANSIENT)
        }
        var rows: [ApprovalRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            rows.append(ApprovalRow(
                id: Int(sqlite3_column_int64(stmt, 0)),
                token: col(1) ?? "", taskId: col(2), question: col(3) ?? "",
                requestedAt: col(4) ?? "", expiresAt: col(5), answeredAt: col(6),
                status: col(7) ?? "", answeredVia: col(8)))
        }
        return rows
    }
}
