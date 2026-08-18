import AppleTasksServerCore
import XCTest

final class BindTests: XCTestCase {
    func testLoopbackDefault() throws {
        let host = try BindResolver.host(mode: .loopback, explicit: nil, unsafeLan: false)
        XCTAssertEqual(host, "127.0.0.1")
    }

    func testWildcardRequiresFlag() {
        XCTAssertThrowsError(try BindResolver.host(mode: .loopback, explicit: "0.0.0.0", unsafeLan: false)) { error in
            guard case BindError.lanBindRequiresFlag = error else {
                return XCTFail("expected lanBindRequiresFlag, got \(error)")
            }
        }
    }

    func testWildcardAllowedWithFlag() throws {
        let host = try BindResolver.host(mode: .loopback, explicit: "0.0.0.0", unsafeLan: true)
        XCTAssertEqual(host, "0.0.0.0")
    }

    func testUnsafeLanWithoutExplicitIsRejected() {
        XCTAssertThrowsError(try BindResolver.host(mode: .loopback, explicit: nil, unsafeLan: true))
    }

    func testAuthConstantTime() {
        let req = HTTPRequest(
            method: "GET",
            path: "/v1/dispatches",
            headers: ["authorization": "Bearer secret-token"],
            body: Data()
        )
        let ok = ServeHTTP(config: ServeConfig(host: "127.0.0.1", port: 1, token: "secret-token"))
        let denied = ServeHTTP(config: ServeConfig(host: "127.0.0.1", port: 1, token: "other"))
        XCTAssertNotEqual(ok.route(req).status, 401)
        XCTAssertEqual(denied.route(req).status, 401)
    }

    func testHealthNeedsNoAuth() {
        let req = HTTPRequest(method: "GET", path: "/v1/health", headers: [:], body: Data())
        let server = ServeHTTP(config: ServeConfig(host: "127.0.0.1", port: 1, token: "x"))
        XCTAssertEqual(server.route(req).status, 200)
    }

    func testServerSourcesDoNotImportEventKit() throws {
        let here = URL(fileURLWithPath: #filePath)
        let sources = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var files: [URL] = []
        var pending = [sources]
        while let dir = pending.popLast() {
            let kids = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for kid in kids {
                if kid.hasDirectoryPath { pending.append(kid) }
                else if kid.pathExtension == "swift" { files.append(kid) }
            }
        }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("import EventKit"), file.lastPathComponent)
            XCTAssertFalse(text.contains("EKEventStore"), file.lastPathComponent)
        }
    }
}
