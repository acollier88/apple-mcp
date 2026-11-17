import XCTest
@testable import apple_tasks

/// All against a temp dir — never the real ~/.config/apple-tasks.
final class ConfigPermissionsTests: XCTestCase {
    private var tempDir: URL!
    private var configDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-perms-\(UUID().uuidString)", isDirectory: true)
        configDir = tempDir.appendingPathComponent("apple-tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    private func write(_ url: URL, mode: Int) throws {
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func mkdir(_ url: URL, mode: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func testNewAuditDBIsOwnerOnly() throws {
        let dbURL = configDir.appendingPathComponent("apple-tasks.db")
        let db = AuditDB(url: dbURL)
        XCTAssertTrue(db.isAvailable)
        db.record(command: "test")
        XCTAssertEqual(try mode(configDir), 0o700)
        XCTAssertEqual(try mode(dbURL), 0o600)
        for sidecar in ConfigPermissions.databaseSidecars(dbURL)
        where FileManager.default.fileExists(atPath: sidecar.path) {
            XCTAssertEqual(try mode(sidecar), 0o600, sidecar.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + "-wal"), "WAL mode expected")
    }

    func testExistingAuditDBIsTightenedOnOpen() throws {
        let dbURL = configDir.appendingPathComponent("apple-tasks.db")
        _ = AuditDB(url: dbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        let db = AuditDB(url: dbURL)
        XCTAssertTrue(db.isAvailable)
        XCTAssertEqual(try mode(configDir), 0o700)
        XCTAssertEqual(try mode(dbURL), 0o600)
    }

    func testTightenOnlyRemovesBits() throws {
        let file = tempDir.appendingPathComponent("f")
        try write(file, mode: 0o400)
        XCTAssertNil(ConfigPermissions.tighten(file, to: 0o600, directory: false))
        XCTAssertEqual(try mode(file), 0o400)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: file.path)
        XCTAssertEqual(ConfigPermissions.tighten(file, to: 0o600, directory: false),
                       .init(path: file.path, from: "664", to: "600"))
    }

    func testTightenSkipsSymlinksAndWrongKinds() throws {
        let target = tempDir.appendingPathComponent("outside")
        try write(target, mode: 0o644)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(ConfigPermissions.tighten(link, to: 0o600, directory: false))
        XCTAssertEqual(try mode(target), 0o644, "symlink target must not be chmod'd")

        let dir = tempDir.appendingPathComponent("d")
        try mkdir(dir, mode: 0o755)
        XCTAssertNil(ConfigPermissions.tighten(dir, to: 0o600, directory: false))
        XCTAssertEqual(try mode(dir), 0o755)
    }

    func testFixModesCoversDirDbLogsRunsAndAgents() throws {
        try mkdir(configDir, mode: 0o755)
        let db = configDir.appendingPathComponent("apple-tasks.db")
        try write(db, mode: 0o644)
        try write(URL(fileURLWithPath: db.path + "-wal"), mode: 0o644)
        try write(URL(fileURLWithPath: db.path + "-shm"), mode: 0o644)
        let logs = configDir.appendingPathComponent("logs", isDirectory: true)
        try mkdir(logs, mode: 0o755)
        try write(logs.appendingPathComponent("dispatch.log"), mode: 0o644)
        let runs = configDir.appendingPathComponent("runs", isDirectory: true)
        try mkdir(runs, mode: 0o755)
        try write(runs.appendingPathComponent("7.log"), mode: 0o644)
        try write(runs.appendingPathComponent("7.prompt"), mode: 0o600)   // already tight
        try write(configDir.appendingPathComponent("agents.json"), mode: 0o644)
        try write(configDir.appendingPathComponent("agents.json.bak-p3"), mode: 0o644)
        try write(configDir.appendingPathComponent("watches.json"), mode: 0o644)  // not in scope

        let changes = ConfigPermissions.fixModes(configDir: configDir)
        let changed = Set(changes.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(changed, [
            "apple-tasks", "apple-tasks.db", "apple-tasks.db-wal", "apple-tasks.db-shm",
            "logs", "dispatch.log", "runs", "7.log", "agents.json", "agents.json.bak-p3",
        ])
        XCTAssertTrue(changes.contains(.init(path: configDir.path, from: "755", to: "700")))

        XCTAssertEqual(try mode(configDir), 0o700)
        XCTAssertEqual(try mode(logs), 0o700)
        XCTAssertEqual(try mode(runs), 0o700)
        XCTAssertEqual(try mode(db), 0o600)
        XCTAssertEqual(try mode(runs.appendingPathComponent("7.log")), 0o600)
        XCTAssertEqual(try mode(configDir.appendingPathComponent("agents.json.bak-p3")), 0o600)
        XCTAssertEqual(try mode(configDir.appendingPathComponent("watches.json")), 0o644)

        XCTAssertEqual(ConfigPermissions.fixModes(configDir: configDir), [], "second pass is a no-op")
    }

    func testFixModesOnMissingDirIsEmpty() {
        XCTAssertEqual(ConfigPermissions.fixModes(configDir: configDir), [])
    }
}
