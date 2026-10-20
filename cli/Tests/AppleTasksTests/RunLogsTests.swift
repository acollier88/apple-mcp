import Foundation
import XCTest
@testable import apple_tasks

final class RunLogsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-runlogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testCreateSetsMode600() throws {
        let path = tempDir.appendingPathComponent("42.log").path
        let handle = RunLogs.create(at: path)
        XCTAssertNotNil(handle)
        handle?.write(Data("hello\n".utf8))
        try handle?.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testWritePrivateSetsMode600() throws {
        let url = tempDir.appendingPathComponent("42.prompt")
        try RunLogs.writePrivate(Data("prompt\n".utf8), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testEnsureDirectorySetsMode700() throws {
        let runs = tempDir.appendingPathComponent("runs", isDirectory: true)
        RunLogs.ensureDirectory(runs)
        let attrs = try FileManager.default.attributesOfItem(atPath: runs.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o700)
    }
}
