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

    func startDispatch(taskId: String, agent: String, command: String, cwd: String?) -> Int64 {
        guard db != nil else { return -1 }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO dispatches (task_id, agent, command, cwd, started_at, status) VALUES (?,?,?,?,?,'running')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [taskId, agent, command, cwd ?? "", Self.now()].enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func finishDispatch(id: Int64, status: String, exitCode: Int32) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE dispatches SET finished_at = ?, status = ?, exit_code = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.now(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, status, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, exitCode)
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
    }

    func dispatchRows(status: String?, limit: Int) -> [DispatchRow] {
        guard db != nil else { return [] }
        var sql = "SELECT id, task_id, agent, command, cwd, started_at, finished_at, status, exit_code FROM dispatches"
        if status != nil { sql += " WHERE status = ?" }
        sql += " ORDER BY id DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let status {
            sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
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
                exitCode: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))))
        }
        return rows
    }
}
